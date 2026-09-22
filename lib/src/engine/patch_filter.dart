import 'dart:io';

import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../models/table_scope.dart';
import 'keep_set.dart';
import 'sqlite_uri.dart';

/// נזרק כשסינון patch נכשל או כשה-patch מכיל משהו שהמנוע מסרב לגעת בו.
class PatchFilterException implements Exception {
  final String message;
  const PatchFilterException(this.message);
  @override
  String toString() => 'PatchFilterException: $message';
}

/// מה נשאר ומה נפל בסינון — נשמר ביומן ומוצג בדוח.
class PatchFilterReport {
  /// שורות שנשמרו, לפי טבלת patch.
  final Map<String, int> kept;

  /// שורות שנפלו, לפי טבלת patch.
  final Map<String, int> dropped;

  /// מחיקות שהמסנן **הוסיף** מעצמו: שורות שקיימות מקומית ושה-patch מעביר
  /// אותן לספר שאינו בבחירה. בלי הסינתזה הזו הן היו נשארות עם הערך הישן.
  final Map<String, int> synthesizedDeletes;

  const PatchFilterReport({
    required this.kept,
    required this.dropped,
    required this.synthesizedDeletes,
  });

  int get totalKept => kept.values.fold(0, (a, b) => a + b);
  int get totalDropped => dropped.values.fold(0, (a, b) => a + b);
  int get totalSynthesizedDeletes =>
      synthesizedDeletes.values.fold(0, (a, b) => a + b);
}

/// מסנן קובץ `patch.db` של אוצריא לתת-קבוצה של ספרים.
///
/// התוצאה היא `patch.db` תקף לכל דבר — אותה סכמה, אותו `patch_meta` —
/// שמכיל רק את השורות שנוגעות לספרים שיש למשתמש. `PatchApplier` של החבילה
/// המעדכנת מחיל אותו בלי לדעת שהוא סונן.
///
/// שלוש החלטות שקובעות את הנכונות:
///
/// 1. **`delete_*` מועתקות במלואן, בלי סינון.** `DELETE ... WHERE pk IN (...)`
///    על שורה שאינה קיימת הוא no-op, ולכן סינון שלהן היה עבודה מיותרת עם
///    סיכוי לטעות. מחיקה של ספר שלא נבחר פשוט לא מוצאת מה למחוק.
///
/// 2. **`upsert_*` מסוננות לפי [kTableScopesInFkOrder].** טבלה שנקבעת לפי
///    ספר — הבדיקה על העמודה עצמה, ישירות מקובץ ה-patch. נמדד על
///    ‏`patch-v16-v17.db` אמיתי: כל טבלת `upsert_` נושאת את **מלוא** עמודות
///    היעד, כולל `bookId` ב-`line` ו-`tocEntry` ושני צדי הקישור ב-`link`.
///    לכן השיוך לספר אינו דורש JOIN למסד המקומי ואינו דורש ניחוש.
///
/// 3. **טבלה שנקבעת לפי הורה נבדקת מול (מקומי ∪ מה שנשמר מה-patch).** ההורה
///    יכול להיות שורה שכבר קיימת אצל המשתמש, או שורה שה-patch עצמו מוסיף
///    באותה החלה. סדר ה-FK מבטיח שההורה כבר סונן כשהצאצא נבדק.
///
/// הפלט הוא החיבור הראשי; ה-patch והמסד החלקי מחוברים **לקריאה בלבד**
/// (`mode=ro`) — ראו [readOnlyUri] להסבר למה הכיוון הזה מחויב.
class PatchFilter {
  const PatchFilter();

  /// אם `migrations` אינה ריקה — לזרוק. מיגרציה היא SQL שרירותי שנכתב
  /// בהנחה שהמסד שלם; אחת שממלאת נתונים (backfill) תיתן על תת-קבוצה
  /// תוצאה אחרת בשקט. הכשל הרועש כאן הוא ההגנה, ומסלול המעבר הוא בנייה
  /// מחדש מ-DB מלא.
  static const bool refuseMigrations = true;

  /// מסנן את [patchPath] לפי הספרים שיש ב-[subsetPath], וכותב ל-[outputPath].
  ///
  /// [bookIds] היא הבחירה **האפקטיבית** — זו שנפתרה מול ה-patch עצמו
  /// דרך `SubsetResolver.resolveForPatch`, ולא זו שנפתרה מול המסד המקומי.
  /// ההבדל הוא ספר חדש בקטגוריה שנבחרה: הוא אינו קיים מקומית, ובלי
  /// ההרחבה הוא היה נופל בסינון ולא מגיע לעולם.
  /// [keepCategoryIds] — גיזום עץ הקטגוריות. חייב להיות **אותה קבוצה**
  /// שאיתה נבנה המסד (`PatchKeepResolution.keepCategories`); `null` פירושו
  /// שהעץ נשמר במלואו. קבוצה שאינה תואמת תחזיר קטגוריה שנגזמה דרך
  /// `upsert_category`, ו-`parentId` שלה יצביע לשורה חסרה.
  PatchFilterReport filter({
    required String patchPath,
    required String subsetPath,
    required String outputPath,
    required Set<int> bookIds,
    Set<int>? keepCategoryIds,
    void Function(String stage)? onStage,
  }) {
    for (final (label, path) in [
      ('קובץ ה-patch', patchPath),
      ('המסד החלקי', subsetPath),
    ]) {
      if (!File(path).existsSync()) {
        throw PatchFilterException('$label אינו קיים: $path');
      }
    }
    final out = File(outputPath);
    if (out.existsSync()) {
      throw PatchFilterException('קובץ הפלט כבר קיים: $outputPath');
    }
    if (!out.parent.existsSync()) out.parent.createSync(recursive: true);

    final db = sqlite3.sqlite3.open(outputPath, uri: true);
    final attached = <String>[];
    try {
      db.execute('ATTACH DATABASE ? AS p', [readOnlyUri(patchPath)]);
      attached.add('p');
      db.execute('ATTACH DATABASE ? AS sub', [readOnlyUri(subsetPath)]);
      attached.add('sub');

      onStage?.call('preflight');
      if (refuseMigrations) _assertNoMigrations(db);

      onStage?.call('schema');
      db.execute('PRAGMA journal_mode = OFF');
      db.execute('PRAGMA synchronous = OFF');
      for (final row in db.select(
        "SELECT sql FROM p.sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' AND sql IS NOT NULL",
      )) {
        db.execute(row['sql'] as String);
      }

      onStage?.call('filter');
      return _copy(db, bookIds, keepCategoryIds);
    } catch (_) {
      for (final s in attached.reversed) {
        try {
          db.execute('DETACH DATABASE $s');
        } catch (_) {}
      }
      db.close();
      try {
        if (out.existsSync()) out.deleteSync();
      } catch (_) {}
      rethrow;
    } finally {
      db.close();
    }
  }

  void _assertNoMigrations(sqlite3.Database db) {
    final has = db
        .select("SELECT 1 FROM p.sqlite_master WHERE type='table' "
            "AND name='migrations' LIMIT 1")
        .isNotEmpty;
    if (!has) return;
    final n =
        db.select('SELECT COUNT(*) c FROM p.migrations').first['c'] as int;
    if (n > 0) {
      throw PatchFilterException(
        'ה-patch מכיל $n מיגרציות סכמה. מיגרציה נכתבת בהנחה שהמסד שלם, '
        'ולכן אינה ניתנת להחלה על ספרייה חלקית. המסלול הוא בנייה מחדש '
        'ממסד מלא.',
      );
    }
  }

  PatchFilterReport _copy(
    sqlite3.Database db,
    Set<int> bookIds,
    Set<int>? keepCategoryIds,
  ) {
    final kept = <String, int>{};
    final dropped = <String, int>{};
    final synthesized = <String, int>{};
    final pruneCategories = keepCategoryIds != null;

    KeepSet.install(db, bookIds);
    if (keepCategoryIds != null) {
      CategoryKeepSet.install(db, keepCategoryIds);
    }
    db.execute('BEGIN');
    try {
      // ── מטא: עובר כמות שהוא. patch_meta נושא את from/to ואת גרסת
      // הפורמט, שה-preflight של PatchApplier בודק מול המניפסט.
      for (final t in const ['patch_meta', 'migrations', 'blobs']) {
        if (!_has(db, 'p', t)) continue;
        _copyAll(db, t);
        kept[t] = db.updatedRows;
      }

      // ── מחיקות: הכל, בלי סינון (ראו הערת המחלקה).
      for (final scope in kTableScopesInFkOrder) {
        final t = 'delete_${scope.name}';
        if (!_has(db, 'p', t)) continue;
        _copyAll(db, t);
        kept[t] = db.updatedRows;
      }

      // ── שדרוגים: בסדר FK, כדי שטבלה שנקבעת לפי הורה תראה את ההורה
      // המסונן שכבר נכתב.
      for (final scope in kTableScopesInFkOrder) {
        final t = 'upsert_${scope.name}';
        if (!_has(db, 'p', t)) continue;
        final cols = _columns(db, 'p', t);
        if (cols.isEmpty) continue;

        final total =
            db.select('SELECT COUNT(*) c FROM p."$t"').first['c'] as int;
        final csv = cols.map((c) => '"$c"').join(',');
        final where = categoryPruneWhere(scope.name, pruneCategories) ??
            _whereFor(db, scope, cols);
        db.execute(
          'INSERT INTO main."$t" ($csv) SELECT $csv FROM p."$t" $where',
        );
        final n = db.updatedRows;
        kept[t] = n;
        if (total - n > 0) dropped[t] = total - n;

        final extra = _synthesizeDeletes(db, scope, cols);
        if (extra > 0) synthesized['delete_${scope.name}'] = extra;
      }

      db.execute('COMMIT');
    } catch (_) {
      try {
        db.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }

    return PatchFilterReport(
      kept: kept,
      dropped: dropped,
      synthesizedDeletes: synthesized,
    );
  }

  void _copyAll(sqlite3.Database db, String table) {
    final cols = _columns(db, 'p', table);
    if (cols.isEmpty) return;
    final csv = cols.map((c) => '"$c"').join(',');
    db.execute('INSERT INTO main."$table" ($csv) SELECT $csv FROM p."$table"');
  }

  /// תנאי הסינון של טבלת `upsert_`.
  ///
  /// [cols] הן העמודות שקיימות בפועל בטבלת ה-patch. אם עמודת השיוך חסרה
  /// (patch שמעדכן תת-קבוצה של עמודות — לא נצפה בפועל, אבל ה-applier
  /// מאפשר זאת), נופלים לבדיקה מול המסד המקומי: שורה שאינה קיימת מקומית
  /// היא שורה של ספר שלא נבחר.
  String _whereFor(sqlite3.Database db, TableScope scope, List<String> cols) {
    switch (scope.kind) {
      case ScopeKind.global:
        return '';

      case ScopeKind.byBook:
        final present =
            scope.bookColumns.where((c) => cols.contains(c)).toList();
        if (present.length == scope.bookColumns.length) {
          final terms = present
              .map((c) => '"$c" IN (${KeepSet.selectIds})')
              .join(' AND ');
          return 'WHERE $terms';
        }
        return _fallbackToLocalPk(scope, cols);

      case ScopeKind.byParent:
        final terms = <String>[];
        for (final r in scope.parents) {
          if (!cols.contains(r.column)) continue;
          final sources = <String>[
            'SELECT "${r.parentColumn}" FROM sub."${r.table}"',
            if (_has(db, 'p', 'upsert_${r.table}'))
              'SELECT "${r.parentColumn}" FROM main."upsert_${r.table}"',
          ];
          terms.add('"${r.column}" IN (${sources.join(" UNION ")})');
        }
        return terms.isEmpty ? '' : 'WHERE ${terms.join(" AND ")}';
    }
  }

  /// נפילה אחורה כשעמודת השיוך אינה בטבלת ה-patch: שומרים רק שורות שה-PK
  /// שלהן כבר קיים מקומית.
  String _fallbackToLocalPk(TableScope scope, List<String> cols) {
    final pk = _primaryKeyOf(scope.name);
    if (pk == null || pk.any((c) => !cols.contains(c))) {
      throw PatchFilterException(
        'לא ניתן לסנן upsert_${scope.name}: חסרות עמודות השיוך '
        '(${scope.bookColumns.join(", ")}) וגם לא ניתן לזהות את השורה '
        'לפי מפתח ראשי. ה-patch אינו מתאים לסינון — נדרשת בנייה מחדש.',
      );
    }
    final csv = pk.map((c) => '"$c"').join(',');
    if (pk.length == 1) {
      return 'WHERE $csv IN (SELECT $csv FROM sub."${scope.name}")';
    }
    return 'WHERE ($csv) IN (SELECT $csv FROM sub."${scope.name}")';
  }

  /// שורה שקיימת מקומית וה-patch מעביר אותה לספר שאינו בבחירה: ה-upsert
  /// נפל, ולכן צריך למחוק אותה במפורש. בלי זה היא נשארת עם התוכן הישן
  /// ומתחזה לשורה מעודכנת.
  int _synthesizeDeletes(
      sqlite3.Database db, TableScope scope, List<String> cols) {
    if (scope.kind != ScopeKind.byBook) return 0;
    final deleteTable = 'delete_${scope.name}';
    if (!_has(db, 'main', deleteTable)) return 0;
    if (!_has(db, 'sub', scope.name)) return 0;

    final pk = _primaryKeyOf(scope.name);
    if (pk == null || pk.any((c) => !cols.contains(c))) return 0;
    final present = scope.bookColumns.where((c) => cols.contains(c)).toList();
    if (present.length != scope.bookColumns.length) return 0;

    final outside =
        present.map((c) => 'u."$c" NOT IN (${KeepSet.selectIds})').join(' OR ');
    final joinOn = pk.map((c) => 's."$c" = u."$c"').join(' AND ');
    final pkCsv = pk.map((c) => '"$c"').join(',');
    final pkSel = pk.map((c) => 'u."$c"').join(',');

    db.execute(
      'INSERT OR IGNORE INTO main."$deleteTable" ($pkCsv) '
      'SELECT $pkSel FROM p."upsert_${scope.name}" u '
      'JOIN sub."${scope.name}" s ON $joinOn '
      'WHERE $outside',
    );
    return db.updatedRows;
  }

  /// עמודות המפתח הראשי של טבלת יעד, מתוך החוזה של החבילה המעדכנת.
  /// שאילתה על הסכמה הייתה מחזירה את אותו דבר, אבל המפתח שה-applier
  /// משתמש בו ב-`ON CONFLICT` הוא זה שקובע — ולכן הוא המקור.
  List<String>? _primaryKeyOf(String table) {
    for (final spec in kPatchTablesInFkOrder) {
      if (spec.name == table) {
        return spec.primaryKey.isEmpty ? null : spec.primaryKey;
      }
    }
    return null;
  }

  bool _has(sqlite3.Database db, String schema, String name) => db.select(
        "SELECT 1 FROM $schema.sqlite_master WHERE type='table' AND name=? LIMIT 1",
        [name],
      ).isNotEmpty;

  List<String> _columns(sqlite3.Database db, String schema, String table) => db
      .select('PRAGMA $schema.table_info("$table")')
      .map((r) => r['name'] as String)
      .toList();
}

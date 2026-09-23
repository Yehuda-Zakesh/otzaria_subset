import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../models/table_scope.dart';
import 'keep_set.dart';
import 'sqlite_uri.dart';

/// נזרק כשבנייה נכשלה. קובץ היעד נמחק לפני הזריקה — אין תת-קבוצה חלקית
/// שנראית תקינה.
class SubsetBuildException implements Exception {
  final String message;
  const SubsetBuildException(this.message);
  @override
  String toString() => 'SubsetBuildException: $message';
}

/// תוצאת בנייה מוצלחת.
class SubsetBuildResult {
  /// כמה שורות הועתקו, לפי טבלה.
  final Map<String, int> rowsCopied;

  /// גודל קובץ התוצאה בבייטים.
  final int resultBytes;

  /// גרסת ה-DB וגרסת הסכמה שנקראו מ-`schema_meta` של המקור.
  final int? dbVersion;
  final int? schemaVersion;

  const SubsetBuildResult({
    required this.rowsCopied,
    required this.resultBytes,
    required this.dbVersion,
    required this.schemaVersion,
  });

  int get totalRows => rowsCopied.values.fold(0, (a, b) => a + b);
}

/// בונה `seforim.db` חלקי מתוך מסד מלא, לפי קבוצת מזהי ספרים.
///
/// **היעד הוא החיבור הראשי; המקור מחובר לקריאה בלבד.** הסדר הזה אינו
/// שרירותי: SQLite מוריש את דגל הקריאה-בלבד מהחיבור הראשי לכל מסד מחובר,
/// ולכן חיבור שנפתח read-only אינו יכול לכתוב גם ליעד כתיב. ההגנה על מסד
/// המשתמש באה מ-`mode=ro` ב-URI של ה-`ATTACH` — ראו [readOnlyUri].
///
/// ה-DDL נוצר ביעד **אות-באות** מ-`sqlite_master` של המקור, בלי הסמכה
/// לסכמה: פקודה לא-מוסמכת רצה בחיבור הראשי, שהוא היעד. כך התוצאה נושאת
/// את אותה סכמה בדיוק, כולל `WITHOUT ROWID` ואילוצי `UNIQUE`.
///
/// אינדקסים נוצרים **אחרי** ההעתקה. יצירתם מראש הייתה מאטה כל `INSERT`
/// בשמירת עץ B נוסף לכל שורה, ועל 4.7GB של `line` זה הבדל של סדר גודל.
///
/// סינכרוני וחוסם — הרץ ב-`Isolate.run`.
class SubsetBuilder {
  const SubsetBuilder();

  /// בונה תת-קבוצה של [bookIds] מ-[sourcePath] אל [targetPath].
  ///
  /// [targetPath] חייב להיות פנוי; קובץ קיים הוא שגיאה ולא דריסה, כדי
  /// שבנייה לא תמחק ספרייה עובדת של המשתמש.
  ///
  /// [onStage] מדווח שם שלב, [onTable] מדווח טבלה וכמה שורות הועתקו בה,
  /// ו-[onTableStart] מדווח על טבלה **לפני** שהעתקתה מתחילה.
  ///
  /// ‏[onTableStart] אינו נוחות: טבלה אחת גדולה נמשכת דקות ארוכות, ובלי
  /// דיווח מוקדם המסך קופא על הטבלה הקודמת — והמשתמש מסיק שהתוכנה תקועה
  /// ועוצר אותה באמצע.
  /// [keepCategoryIds] — גיזום עץ הקטגוריות. `null` שומר את העץ **במלואו**
  /// (ברירת המחדל, והתנהגות אוצריא המקורית). כשמסופק, `category`
  /// ו-`category_closure` מסוננות אליו — ראו `CategoryKeepSet` להסבר למה
  /// דווקא שתי הטבלאות האלה מותרות בגיזום, ומה הכלל שקובע מה נשאר.
  ///
  /// חשוב: הקבוצה חייבת להכיל את הקטגוריות של **כל** הספרים ב-[bookIds]
  /// ואת אבותיהן, אחרת `book.categoryId` יצביע לשורה שאינה שם
  /// וה-`foreign_key_check` בסוף יזרוק. `SubsetResolver.resolveCategoryIds`
  /// מחשב קבוצה כזו.
  SubsetBuildResult build({
    required String sourcePath,
    required String targetPath,
    required Set<int> bookIds,
    Set<int>? keepCategoryIds,
    void Function(String stage)? onStage,
    void Function(String table, int rows)? onTable,
    void Function(String table, int index, int total)? onTableStart,
    void Function(int done, int total)? onIndex,
  }) {
    if (!File(sourcePath).existsSync()) {
      throw SubsetBuildException('מסד המקור אינו קיים: $sourcePath');
    }
    final target = File(targetPath);
    if (target.existsSync()) {
      throw SubsetBuildException('קובץ היעד כבר קיים: $targetPath');
    }
    if (!target.parent.existsSync()) {
      target.parent.createSync(recursive: true);
    }

    // ‏uri: true נדרש כדי ש-mode=ro ב-ATTACH ייחשב בכלל. בלעדיו SQLite
    // מחפש קובץ שנקרא ממש "file:...?mode=ro", לא מוצא, ויוצר מסד ריק —
    // כשל שקט שהיה מייצר תת-קבוצה ריקה בלי הודעה.
    final db = sqlite3.sqlite3.open(targetPath, uri: true);
    var attached = false;
    try {
      db.execute('ATTACH DATABASE ? AS full', [readOnlyUri(sourcePath)]);
      attached = true;

      onStage?.call('preflight');
      _assertAllTablesClassified(db);
      final dbVersion = _readMetaInt(db, 'db_version');
      final schemaVersion = _readMetaInt(db, 'db_schema_version');

      onStage?.call('schema');
      // ‏**חייב להיקבע לפני שנוצרת הטבלה הראשונה** — אחר כך שינוי המצב
      // דורש `VACUUM` מלא. זה מה שמאפשר להסרה הבאה למחוק שורות במקום
      // ולשחרר את הדף לדיסק בלי לכתוב את כל המסד מחדש; ראו `SubsetPruner`.
      db.execute('PRAGMA auto_vacuum = INCREMENTAL');
      db.execute('PRAGMA main.journal_mode = OFF');
      db.execute('PRAGMA main.synchronous = OFF');
      db.execute('PRAGMA foreign_keys = OFF');
      // ‏מטמון של 256MB במקום 2MB כברירת מחדל. בניית האינדקסים בסוף
      // ממיינת מיליוני שורות, ומטמון קטן שולח כל מיון לדיסק — זה ההפרש
      // בין דקות לעשרות דקות, והזיכרון משוחרר בסגירת החיבור.
      db.execute('PRAGMA cache_size = -262144');
      // מיון האינדקסים ב-RAM ולא בקובץ זמני על הדיסק.
      db.execute('PRAGMA temp_store = MEMORY');
      // קריאת המקור דרך מיפוי זיכרון חוסכת העתקה לכל בלוק. הכישלון כאן
      // אינו קריטי — מערכת שאינה תומכת פשוט תקרא כרגיל.
      try {
        db.execute('PRAGMA full.mmap_size = 1073741824');
      } catch (_) {}
      _runDdl(db, "type='table'");

      onStage?.call('copy');
      KeepSet.install(db, bookIds);
      if (keepCategoryIds != null) {
        CategoryKeepSet.install(db, keepCategoryIds);
      }
      final rows = _copyRows(
        db,
        pruneCategories: keepCategoryIds != null,
        onTable: onTable,
        onTableStart: onTableStart,
      );

      onStage?.call('indexes');
      _runDdl(
        db,
        "type IN ('index','view','trigger')",
        onEach: onIndex,
      );

      db.execute('DETACH DATABASE full');
      attached = false;

      // ‏`ANALYZE` בלי שם סכמה מנתח **כל** מסד מחובר וכותב `sqlite_stat1`
      // בכל אחד מהם — כולל המקור, שמחובר לקריאה בלבד. לכן הוא רץ אחרי
      // ה-DETACH, ומוסמך ל-main בכל מקרה.
      onStage?.call('analyze');
      // ‏`ANALYZE` מלא סורק כל אינדקס מקצה לקצה, וזה שווה בזמן לבנייה
      // עצמה. `analysis_limit` עוצר כל אינדקס אחרי מדגם — הסטטיסטיקה
      // נשארת טובה דיה למתכנן השאילתות, וזה מה שהיא צריכה להיות.
      db.execute('PRAGMA analysis_limit = 1000');
      db.execute('ANALYZE main');

      onStage?.call('verify');
      _verify(db);

      return SubsetBuildResult(
        rowsCopied: rows,
        resultBytes: target.lengthSync(),
        dbVersion: dbVersion,
        schemaVersion: schemaVersion,
      );
    } catch (_) {
      // תת-קבוצה חלקית מסוכנת יותר מכלום: היא נראית כמו ספרייה עובדת.
      if (attached) {
        try {
          db.execute('DETACH DATABASE full');
        } catch (_) {}
      }
      db.close();
      try {
        if (target.existsSync()) target.deleteSync();
      } catch (_) {}
      rethrow;
    } finally {
      db.close();
    }
  }

  /// מריץ ביעד את הצהרות ה-DDL של המקור שתואמות את [filter].
  ///
  /// [onEach] מדווח לפני כל הצהרה. בניית אינדקס על מיליוני שורות נמשכת
  /// דקות, ובלי דיווח כל שלב האינדקסים נראה כמו תקיעה אחת ארוכה.
  void _runDdl(
    sqlite3.Database db,
    String filter, {
    void Function(int done, int total)? onEach,
  }) {
    final statements = [
      for (final row in db.select(
        'SELECT sql FROM full.sqlite_master WHERE $filter '
        "AND name NOT LIKE 'sqlite_%' AND sql IS NOT NULL",
      ))
        row['sql'] as String,
    ];
    for (var i = 0; i < statements.length; i++) {
      onEach?.call(i + 1, statements.length);
      db.execute(statements[i]);
    }
  }

  /// טבלה בסכמת המקור שאינה מסווגת ב-[kTableScopesInFkOrder] פירושה סכמה
  /// חדשה שהמנוע אינו מכיר. **עוצרים בקול** — ההתנהגות השקטה (להשמיט
  /// אותה) הייתה מייצרת ספרייה חסרה בלי שאף אחד יידע.
  void _assertAllTablesClassified(sqlite3.Database db) {
    final unknown = <String>[];
    for (final row in db.select(
      "SELECT name FROM full.sqlite_master WHERE type='table' "
      "AND name NOT LIKE 'sqlite_%'",
    )) {
      final name = row['name'] as String;
      if (scopeFor(name) == null) unknown.add(name);
    }
    if (unknown.isNotEmpty) {
      throw SubsetBuildException(
        'טבלאות שאינן מסווגות במנוע: ${unknown.join(", ")}. '
        'הסכמה התקדמה — יש לסווג אותן ב-kTableScopesInFkOrder לפני שאפשר '
        'לבנות ספרייה חלקית ממסד כזה.',
      );
    }
  }

  /// מעתיק את השורות שבתחום, בסדר מפתח זר.
  Map<String, int> _copyRows(
    sqlite3.Database db, {
    required bool pruneCategories,
    void Function(String table, int rows)? onTable,
    void Function(String table, int index, int total)? onTableStart,
  }) {
    final counts = <String, int>{};
    final total = kTableScopesInFkOrder.length;
    var index = 0;
    db.execute('BEGIN');
    try {
      for (final scope in kTableScopesInFkOrder) {
        index++;
        if (!_hasTable(db, 'full', scope.name)) continue;
        onTableStart?.call(scope.name, index, total);
        final cols = _columns(db, 'full', scope.name);
        if (cols.isEmpty) continue;
        final csv = cols.map((c) => '"$c"').join(',');
        final where =
            categoryPruneWhere(scope.name, pruneCategories) ?? _whereFor(scope);
        db.execute(
          'INSERT INTO main."${scope.name}" ($csv) '
          'SELECT $csv FROM full."${scope.name}" $where',
        );
        final n = db.updatedRows;
        counts[scope.name] = n;
        onTable?.call(scope.name, n);
      }
      db.execute('COMMIT');
    } catch (_) {
      try {
        db.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
    return counts;
  }

  /// תנאי ה-`WHERE` של טבלה, לפי הסיווג שלה.
  ///
  /// ל-[ScopeKind.byParent] התנאי מצביע על **טבלת ההורה שביעד**
  /// (`main.<parent>`), לא על המקור: "ההורה שרד" פירושו שהוא כבר הועתק,
  /// וסדר ה-FK מבטיח שההעתקה שלו קדמה לזו של הצאצא.
  ///
  /// ## למה `EXISTS` ולא `IN`
  ///
  /// ‏`IN (SELECT id FROM main.line)` גורם ל-SQLite לממש את כל המזהים
  /// של ההורה בטבלה זמנית — מיליוני שורות — לפני שהוא בודק שורה אחת.
  /// על טבלאות הקישור זה נראה בדיוק כמו תקיעה: קריאה רצופה מהדיסק,
  /// מעבד ב-100%, וכלום לא נכתב ליעד במשך דקות ארוכות. `EXISTS` על
  /// עמודת מפתח הוא חיפוש rowid בודד לכל שורה, בלי מימוש בכלל.
  ///
  /// ‏[ScopeKind.byBook] נשאר `IN`: `temp._keep` הוא אלפי שורות בודדות,
  /// והמימוש שלו זול ואף מועיל.
  String _whereFor(TableScope scope) {
    switch (scope.kind) {
      case ScopeKind.global:
        return '';
      case ScopeKind.byBook:
        final terms = scope.bookColumns
            .map((c) => '"$c" IN (${KeepSet.selectIds})')
            .join(' AND ');
        return 'WHERE $terms';
      case ScopeKind.byParent:
        final terms = scope.parents
            .map((r) => 'EXISTS (SELECT 1 FROM main."${r.table}" AS _p '
                'WHERE _p."${r.parentColumn}" = "${scope.name}"."${r.column}")')
            .join(' AND ');
        return 'WHERE $terms';
    }
  }

  /// מוודא שהתוצאה שלמה מבחינת ייחוס. אם המנוע ניתק שורה בטעות, היא
  /// מופיעה כאן — וזה בדיוק המקום שבו עדיף להיכשל.
  void _verify(sqlite3.Database db) {
    db.execute('PRAGMA foreign_keys = ON');
    final violations = db.select('PRAGMA main.foreign_key_check');
    if (violations.isNotEmpty) {
      final sample = violations.take(5).map((r) => r.values.join('/'));
      throw SubsetBuildException(
        'הפרות מפתח זר בתת-הקבוצה (${violations.length}): '
        '${sample.join(" · ")}',
      );
    }
    final integrity =
        db.select('PRAGMA main.quick_check').first.values.first as String;
    if (integrity != 'ok') {
      throw SubsetBuildException('quick_check נכשל: $integrity');
    }
  }

  bool _hasTable(sqlite3.Database db, String schema, String name) => db.select(
        "SELECT 1 FROM $schema.sqlite_master WHERE type='table' AND name=? LIMIT 1",
        [name],
      ).isNotEmpty;

  List<String> _columns(sqlite3.Database db, String schema, String table) => db
      .select('PRAGMA $schema.table_info("$table")')
      .map((r) => r['name'] as String)
      .toList();

  int? _readMetaInt(sqlite3.Database db, String key) {
    try {
      final rows = db.select(
        'SELECT value FROM full.schema_meta WHERE key = ? LIMIT 1',
        [key],
      );
      if (rows.isEmpty) return null;
      return int.tryParse(rows.first['value']?.toString() ?? '');
    } catch (_) {
      return null;
    }
  }
}

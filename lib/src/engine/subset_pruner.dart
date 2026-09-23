import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../models/table_scope.dart';
import 'keep_set.dart';

/// נזרק כשגזימה במקום נכשלה. המסד מגולגל אחורה ונשאר כשהיה.
class SubsetPruneException implements Exception {
  final String message;
  const SubsetPruneException(this.message);
  @override
  String toString() => 'SubsetPruneException: $message';
}

/// תוצאת גזימה במקום.
class SubsetPruneResult {
  /// כמה שורות נמחקו, לפי טבלה.
  final Map<String, int> rowsDeleted;

  /// גודל הקובץ אחרי שחרור הדפים.
  final int resultBytes;

  /// כמה בייטים שוחררו בפועל.
  final int freedBytes;

  const SubsetPruneResult({
    required this.rowsDeleted,
    required this.resultBytes,
    required this.freedBytes,
  });

  int get totalRows => rowsDeleted.values.fold(0, (a, b) => a + b);
}

/// מוחק ספרים **מתוך** ספרייה קיימת, בלי לבנות אותה מחדש.
///
/// ## למה זה קיים לצד `SubsetRebuilder`
///
/// בנייה מחדש מעתיקה את כל מה שנשאר — ולכן הזמן שלה תלוי בגודל **מה
/// שנשאר**, לא במה שנמחק. הסרה של ספר בודד מספרייה של 7GB עלתה בה
/// כמעט כמו בנייה מאפס. כאן ההפך: העבודה תלויה במה שיורד בלבד.
///
/// ## למה זה אפשרי רק על מסד שאנחנו בנינו
///
/// מחיקת שורות ב-SQLite אינה מקטינה את הקובץ — היא מסמנת דפים כפנויים.
/// שחרורם לדיסק בלי לכתוב את המסד מחדש דורש `auto_vacuum = INCREMENTAL`,
/// ומצב זה נקבע **ביצירת המסד** ואינו ניתן לשינוי אחר כך אלא ב-`VACUUM`
/// מלא. `SubsetBuilder` קובע אותו, ולכן הבנייה הראשונה נשארת בנייה מלאה
/// וכל הסרה שאחריה מהירה.
///
/// ## למה סדר המחיקה הפוך מסדר ההעתקה
///
/// אין כאן היפוך. המחיקה רצה **באותו סדר FK** כמו ההעתקה, ומפתחות זרים
/// כבויים בזמנה: ההורה נמחק ראשון, ואז הצאצא מזוהה כיתום בבדיקת
/// ‏`NOT EXISTS` מול ההורה שכבר נגזם. הסדר ההפוך היה מחייב לדעת מראש
/// מי **עומד** להימחק, וזו בדיוק העבודה שאנחנו מנסים לחסוך.
///
/// סינכרוני וחוסם — הרץ ב-`Isolate.run`.
class SubsetPruner {
  const SubsetPruner();

  /// האם [path] נבנה במצב שמאפשר שחרור מקום בלי בנייה מחדש.
  static bool supportsInPlace(String path) {
    if (!File(path).existsSync()) return false;
    final db = sqlite3.sqlite3.open(path, mode: sqlite3.OpenMode.readOnly);
    try {
      final rows = db.select('PRAGMA auto_vacuum');
      if (rows.isEmpty) return false;
      // ‏2 = INCREMENTAL. 0 (NONE) ו-1 (FULL) אינם תומכים ב-
      // `incremental_vacuum`, ולכן שם המסלול היחיד הוא בנייה מחדש.
      return (rows.first.values.first as num?)?.toInt() == 2;
    } catch (_) {
      return false;
    } finally {
      db.close();
    }
  }

  /// מוחק מ-[path] את הספרים שב-[dropBookIds] ואת הקטגוריות שאינן
  /// ב-[keepCategoryIds].
  ///
  /// [keepCategoryIds] `null` משאיר את עץ הקטגוריות כשהוא. אחרת הוא
  /// נגזם **בדיוק** לפי אותו תנאי שבו המסד נבנה — ראו `categoryPruneWhere`.
  SubsetPruneResult prune({
    required String path,
    required Set<int> dropBookIds,
    Set<int>? keepCategoryIds,
    void Function(String stage)? onStage,
    void Function(String table, int rows)? onTable,
    void Function(String table, int index, int total)? onTableStart,
    void Function(int freedBytes)? onVacuum,
  }) {
    final file = File(path);
    if (!file.existsSync()) {
      throw SubsetPruneException('הספרייה אינה קיימת: $path');
    }
    if (dropBookIds.isEmpty && keepCategoryIds == null) {
      throw const SubsetPruneException('אין מה למחוק.');
    }
    final before = file.lengthSync();
    final db = sqlite3.sqlite3.open(path);

    try {
      onStage?.call('preflight');
      // מפתחות זרים כבויים: ההורה נמחק לפני הצאצא, ובין השניים המסד
      // אינו עקבי. `foreign_key_check` בסוף הוא מה שמוכיח שהוא חזר להיות.
      db.execute('PRAGMA foreign_keys = OFF');
      db.execute('PRAGMA cache_size = -262144');
      db.execute('PRAGMA temp_store = MEMORY');

      onStage?.call('delete');
      final deleted = _deleteRows(
        db,
        dropBookIds: dropBookIds,
        keepCategoryIds: keepCategoryIds,
        onTable: onTable,
        onTableStart: onTableStart,
        onVerify: () => onStage?.call('verify'),
      );

      // שחרור הדפים הפנויים לדיסק. בלעדיו הקובץ נשאר בגודלו המלא וכל
      // התרגיל לא נתן למשתמש כלום.
      onStage?.call('reclaim');
      db.execute('PRAGMA incremental_vacuum');
      db.execute('PRAGMA optimize');
      db.close();

      final after = File(path).lengthSync();
      onVacuum?.call(before - after);
      return SubsetPruneResult(
        rowsDeleted: deleted,
        resultBytes: after,
        freedBytes: before - after < 0 ? 0 : before - after,
      );
    } catch (e) {
      try {
        db.close();
      } catch (_) {}
      if (e is SubsetPruneException) rethrow;
      throw SubsetPruneException('הגזימה נכשלה: $e');
    }
  }

  /// מוחק בסדר מפתח זר: הורה לפני צאצא.
  Map<String, int> _deleteRows(
    sqlite3.Database db, {
    required Set<int> dropBookIds,
    Set<int>? keepCategoryIds,
    void Function(String table, int rows)? onTable,
    void Function(String table, int index, int total)? onTableStart,
    void Function()? onVerify,
  }) {
    final counts = <String, int>{};
    final total = kTableScopesInFkOrder.length;
    var index = 0;

    KeepSet.install(db, dropBookIds);
    if (keepCategoryIds != null) {
      CategoryKeepSet.install(db, keepCategoryIds);
    }

    db.execute('BEGIN');
    try {
      for (final scope in kTableScopesInFkOrder) {
        index++;
        if (!_hasTable(db, scope.name)) continue;
        final where = _whereFor(scope, keepCategoryIds != null);
        if (where == null) continue;
        onTableStart?.call(scope.name, index, total);
        db.execute('DELETE FROM "${scope.name}" $where');
        final n = db.updatedRows;
        counts[scope.name] = n;
        onTable?.call(scope.name, n);
      }
      // האימות **לפני** ה-COMMIT: אחריו אין לאן לגלגל, והמסד היה נשאר
      // שבור על הדיסק למרות ההודעה שהוא "גולגל אחורה".
      onVerify?.call();
      _verify(db);
      db.execute('COMMIT');
    } catch (_) {
      try {
        db.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    } finally {
      KeepSet.drop(db);
      if (keepCategoryIds != null) CategoryKeepSet.drop(db);
    }
    return counts;
  }

  /// התנאי שמזהה את השורות שיורדות. `null` = הטבלה אינה נוגעת בגזימה.
  ///
  /// זהו **המשלים המדויק** של התנאי ב-`SubsetBuilder`: שם נשמרת שורה
  /// שכל הפניותיה שרדו, וכאן נמחקת שורה שאחת מהן לא.
  String? _whereFor(TableScope scope, bool pruneCategories) {
    switch (scope.name) {
      case 'category':
        return pruneCategories
            ? 'WHERE "id" NOT IN (${CategoryKeepSet.selectIds})'
            : null;
      case 'category_closure':
        return pruneCategories
            ? 'WHERE "ancestorId" NOT IN (${CategoryKeepSet.selectIds}) '
                'OR "descendantId" NOT IN (${CategoryKeepSet.selectIds})'
            : null;
    }
    switch (scope.kind) {
      case ScopeKind.global:
        // טבלאות גלובליות נשמרות במלואן גם בבנייה — ראו §2 ב-AGENTS.md.
        return null;
      case ScopeKind.byBook:
        final terms = scope.bookColumns
            .map((c) => '"$c" IN (${KeepSet.selectIds})')
            .join(' OR ');
        return 'WHERE $terms';
      case ScopeKind.byParent:
        final terms = scope.parents
            .map((r) => 'NOT EXISTS (SELECT 1 FROM "${r.table}" AS _p '
                'WHERE _p."${r.parentColumn}" = "${scope.name}"."${r.column}")')
            .join(' OR ');
        return 'WHERE $terms';
    }
  }

  /// ‏`foreign_key_check` בודק גם כשאכיפת המפתחות כבויה, ולכן הוא רץ
  /// בתוך הטרנזקציה, שם `PRAGMA foreign_keys` אינו ניתן לשינוי.
  void _verify(sqlite3.Database db) {
    final violations = db.select('PRAGMA main.foreign_key_check');
    if (violations.isNotEmpty) {
      throw SubsetPruneException(
        'הגזימה השאירה ${violations.length} הפרות מפתח זר. המסד גולגל '
        'אחורה ונשאר כשהיה.',
      );
    }
  }

  bool _hasTable(sqlite3.Database db, String name) => db.select(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?",
        [name],
      ).isNotEmpty;
}

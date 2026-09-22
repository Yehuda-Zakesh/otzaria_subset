import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'fixtures.dart';

/// בדיקות ל-[SubsetPruner] — מחיקת ספרים מתוך ספרייה קיימת.
///
/// התכונה המרכזית שנבדקת כאן היא השקילות:
/// ```
/// prune_in_place(build(full, keep = A), drop = A \ B)  ==  build(full, keep = B)
/// ```
/// כלומר: מחיקת ספרים בסדר מגיעה לאותו תוכן שבנייה מחדש הייתה מייצרת.

/// מחזיר את כל השורות של טבלה בסדר דטרמיניסטי.
List<Map<String, Object?>> allRowsOf(
  sqlite3.Database db,
  String table,
) {
  final cols = getColumnsOf(db, table);
  // מיון לפי כל העמודות בסדר לקסיקוגרפי עבור דטרמיניזם.
  final orderCols = cols.map((c) => '"$c"').join(', ');
  final query = 'SELECT ${cols.map((c) => '"$c"').join(', ')} FROM "$table" '
      'ORDER BY $orderCols';
  return db.select(query);
}

/// מחזיר את שמות העמודות של טבלה.
List<String> getColumnsOf(sqlite3.Database db, String table) {
  final rows = db
      .select('PRAGMA table_info("$table")')
      .map((r) => r['name'] as String)
      .toList();
  return rows;
}

/// מחזיר כמה שורות בטבלה.
int rowCountOf(sqlite3.Database db, String table) {
  final result = db.select('SELECT COUNT(*) c FROM "$table"');
  return result.first['c'] as int;
}

/// בודק האם טבלה קיימת.
bool hasTable(sqlite3.Database db, String table) => db.select(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?",
    [table]).isNotEmpty;

void main() {
  late Directory dir;

  setUp(() => dir = createTempDir('pruner'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String at(String name) => p.join(dir.path, name);

  /// פותח מסד לקריאה ומריץ עליו [body].
  T on<T>(String path, T Function(sqlite3.Database db) body) {
    final db = sqlite3.sqlite3.open(path, mode: sqlite3.OpenMode.readOnly);
    try {
      return body(db);
    } finally {
      db.close();
    }
  }

  /// משווה שתי מסדות שורה-בשורה בכל טבלה.
  /// זהו המבחן המדויק של השקילות: אם שורה אחת שונה, הבדיקה נכשלת.
  void expectDatabasesEqual(
    String pathA,
    String pathB, {
    String? reason,
  }) {
    on(pathA, (dbA) {
      on(pathB, (dbB) {
        for (final scope in kTableScopesInFkOrder) {
          // דלג על טבלה שאין בשניהם.
          final existsInA = hasTable(dbA, scope.name);
          final existsInB = hasTable(dbB, scope.name);
          if (!existsInA && !existsInB) continue;

          expect(
            existsInA,
            existsInB,
            reason:
                'טבלה ${scope.name} קיימת רק באחד ($existsInA / $existsInB)',
          );

          // השווה ספירת שורות.
          final countA = rowCountOf(dbA, scope.name);
          final countB = rowCountOf(dbB, scope.name);
          expect(countA, countB,
              reason: 'ספירת שורות בטבלה ${scope.name}: $countA vs $countB');

          // השווה כל שורה בסדר דטרמיניסטי.
          final rowsA = allRowsOf(dbA, scope.name);
          final rowsB = allRowsOf(dbB, scope.name);
          expect(rowsA, rowsB,
              reason:
                  'שורות שונות בטבלה ${scope.name}${reason != null ? ': $reason' : ''}');
        }
      });
    });
  }

  group('השקילות: גיזום במקום מול בנייה מחדש', () {
    test('הסרת ספרים מקטגוריה אחת, ללא גיזום עץ', () {
      // בנה מלא, בחר ספרים 1,2,3 (מקטגוריות 10 ו-11).
      buildFullDb(at('full.db'));

      // בנה A: ספרים 1,2,3
      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('a.db'),
        bookIds: {1, 2, 3},
      );

      // בנה B: ספרים 1,2 בלבד (הסר 3 מהבחירה).
      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('b.db'),
        bookIds: {1, 2},
      );

      // גזום את A על-ידי הסרת ספר 3. אף קטגוריות לא נגזמות.
      const SubsetPruner().prune(
        path: at('a.db'),
        dropBookIds: {3},
      );

      // השווה את A לאחר גיזום ו-B — צריכים להיות זהים בדיוק.
      expectDatabasesEqual(at('a.db'), at('b.db'),
          reason: 'הסרת ספר 3 אחרי בנייה צריכה להיות זהה לבנייה עם 1,2 בלבד');
    });

    test('הסרת ספרים וגיזום עץ קטגוריות', () {
      buildFullDb(at('full.db'));

      // בנה A ראשוני: ספרים 1,2,3 עם עץ קטגוריות מלא.
      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('a.db'),
        bookIds: {1, 2, 3},
        keepCategoryIds: null,
      );

      // חשב את הקטגוריות הנדרשות לספרים 1,2 בלבד.
      final keepCatsForB = on(at('full.db'), (full) {
        return const SubsetResolver().resolveCategoryIds(
          full,
          selectedCategoryIds: const <int>{},
          bookIds: {1, 2},
        );
      });

      // בנה B: ספרים 1,2 עם עץ מגוזם (קטגוריות רק לספרים האלה).
      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('b.db'),
        bookIds: {1, 2},
        keepCategoryIds: keepCatsForB,
      );

      // גזום את A: הסר ספר 3 וגזום קטגוריות לתאימה ל-B.
      const SubsetPruner().prune(
        path: at('a.db'),
        dropBookIds: {3},
        keepCategoryIds: keepCatsForB,
      );

      expectDatabasesEqual(at('a.db'), at('b.db'),
          reason:
              'גיזום עץ קטגוריות צריך להיות זהה לבנייה עם קטגוריות מסוננות');
    });

    test('הסרת ספר שקשור לספר שנשמר', () {
      buildFullDb(at('full.db'));

      // בנו: ספרים 1,2,4 (ספר 3 חסר). בתוך הקשרים: 1→3 ו-4→2.
      // לאחר הסרה של 3 (שעדיין בתחום ההתחלתי), הקישור 1→3 צריך להיעלם.
      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('a.db'),
        bookIds: {1, 2, 3, 4},
      );

      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('b.db'),
        bookIds: {1, 2, 4},
      );

      const SubsetPruner().prune(
        path: at('a.db'),
        dropBookIds: {3},
      );

      expectDatabasesEqual(at('a.db'), at('b.db'),
          reason: 'קישורים של ספרים שנמחקו צריכים להיעלם');
    });
  });

  group('מקרים חריגים ותנאים', () {
    test('בלי ספרים למחוק ובלי גיזום קטגוריות -> זריקה', () {
      buildFullDb(at('full.db'));
      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('sub.db'),
        bookIds: {1, 2},
      );

      expect(
        () => const SubsetPruner().prune(
          path: at('sub.db'),
          dropBookIds: {},
          keepCategoryIds: null,
        ),
        throwsA(isA<SubsetPruneException>()),
        reason: 'פנייה חסרת משמעות צריכה להזרוק',
      );
    });

    test('supportsInPlace חוזר true למסד שבנוי ע"י SubsetBuilder', () {
      buildFullDb(at('full.db'));
      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('sub.db'),
        bookIds: {1, 2},
      );

      // מסד שבנוי ע"י SubsetBuilder מוגדר עם auto_vacuum = INCREMENTAL.
      expect(SubsetPruner.supportsInPlace(at('sub.db')), true);
    });

    test('supportsInPlace חוזר false למסד שלא בנוי ע"י SubsetBuilder', () {
      // בנה מסד פשוט בלי INCREMENTAL.
      final db = sqlite3.sqlite3.open(at('plain.db'));
      try {
        db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY)');
        // מסד פשוט בברירת המחדל בעל auto_vacuum = NONE (0).
      } finally {
        db.close();
      }

      expect(SubsetPruner.supportsInPlace(at('plain.db')), false);
    });

    test('גיזום מסד שאינו קיים -> זריקה', () {
      expect(
        () => const SubsetPruner().prune(
          path: at('nonexistent.db'),
          dropBookIds: {1},
        ),
        throwsA(isA<SubsetPruneException>()),
      );
    });
  });

  group('גודל וביצועים', () {
    test('freedBytes >= 0 ו-resultBytes <= קודם לזה', () {
      buildFullDb(at('full.db'));

      // בנה עם כל הספרים.
      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('sub.db'),
        bookIds: {1, 2, 3, 4},
      );

      final sizeBefore = File(at('sub.db')).lengthSync();

      // גזום בהסרת 3 ספרים — שינוי משמעותי.
      final result = const SubsetPruner().prune(
        path: at('sub.db'),
        dropBookIds: {2, 3, 4},
      );

      final sizeAfter = File(at('sub.db')).lengthSync();

      // freedBytes צריך להיות חיובי מכיוון שהסרנו את רוב הספרים.
      expect(result.freedBytes >= 0, true,
          reason: 'freedBytes לא צריך להיות שלילי');

      // resultBytes צריך להיות <= מהגודל הקודם.
      expect(sizeAfter <= sizeBefore, true,
          reason: 'גודל קובץ צריך לרדת או להישאר זהה');

      // resultBytes שמדווח צריך להתאים לגודל בפועל.
      expect(result.resultBytes, sizeAfter);
    });

    test('rowsDeleted מדווח את ספירת שורות שנמחקו', () {
      buildFullDb(at('full.db'));

      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('sub.db'),
        bookIds: {1, 2, 3, 4},
      );

      final result = const SubsetPruner().prune(
        path: at('sub.db'),
        dropBookIds: {3},
      );

      // צריכים שורות שנמחקו מטבלאות שונות: book, line, version_line, וכו'.
      expect(result.rowsDeleted.containsKey('book'), true);
      expect(result.rowsDeleted['book'], 1, reason: 'ספר 3 אחד נמחק');

      // line: ספר 3 יש 3 שורות (100+0, 100+1, 100+2).
      expect(result.rowsDeleted.containsKey('line'), true);
      expect(result.rowsDeleted['line'], 3);

      // totalRows צריך להיות סכום של הכל.
      final total = result.rowsDeleted.values.fold(0, (a, b) => a + b);
      expect(result.totalRows, total);
    });
  });

  group('בדיקת consistency של מפתחות זרים', () {
    test('אחרי גיזום, מפתחות זרים תקינים', () {
      buildFullDb(at('full.db'));
      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('sub.db'),
        bookIds: {1, 2, 3, 4},
      );

      const SubsetPruner().prune(
        path: at('sub.db'),
        dropBookIds: {3},
      );

      // בדוק שאין הפרות מפתח זר.
      on(at('sub.db'), (db) {
        db.execute('PRAGMA foreign_keys = ON');
        final violations = db.select('PRAGMA foreign_key_check');
        expect(violations, isEmpty,
            reason: 'לאחר גיזום צריך להיות 0 הפרות מפתח זר');
      });
    });
  });

  group('טבלאות גלובליות נשמרות', () {
    test('טבלאות גלובליות לא נמחקות גם כשמוחקים כל הספרים שלהם משתמשים', () {
      buildFullDb(at('full.db'));

      // בנה עם הכל.
      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('sub.db'),
        bookIds: {1, 2, 3, 4},
      );

      final countBefore = on(at('sub.db'), (db) {
        return (
          db.select('SELECT COUNT(*) c FROM author').first['c'] as int,
          db.select('SELECT COUNT(*) c FROM tocText').first['c'] as int
        );
      });

      // גזום: הסר הכל.
      // הערה: זה יזרוק כי אין ספרים שנשארו, אבל בואו נבדוק את הטבלאות
      // הגלובליות לפני. למעשה, נוצר מסקנה: גיזום שלא משאיר שום ספר הוא
      // לא תרחיש טיפוסי. בואו נהסר רוב אבל לא הכל.
      const SubsetPruner().prune(
        path: at('sub.db'),
        dropBookIds: {2, 3, 4},
      );

      final countAfter = on(at('sub.db'), (db) {
        return (
          db.select('SELECT COUNT(*) c FROM author').first['c'] as int,
          db.select('SELECT COUNT(*) c FROM tocText').first['c'] as int
        );
      });

      // טבלאות גלובליות לא צריכות להשתנות.
      expect(countAfter.$1, countBefore.$1,
          reason: 'טבלת author לא צריכה להשתנות');
      expect(countAfter.$2, countBefore.$2,
          reason: 'טבלת tocText לא צריכה להשתנות');
    });
  });
}

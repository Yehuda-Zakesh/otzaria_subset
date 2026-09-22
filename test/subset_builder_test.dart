import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'fixtures.dart';

/// בדיקות ל-[SubsetBuilder] — גיזום מסד מלא לקבוצת ספרים.
///
/// שתי תכונות התכנון שנבדקות כאן שוב ושוב: הטבלאות הגלובליות נשמרות
/// **במלואן** (בלעדיהן אילוצי ה-UNIQUE הגלובליים מתפרקים), והמקור אינו
/// נכתב לעולם (הוא 7.4GB שאין לשחזר).
void main() {
  late Directory dir;

  setUp(() => dir = createTempDir('builder'));
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

  int rows(sqlite3.Database db, String table) =>
      db.select('SELECT COUNT(*) c FROM "$table"').first['c'] as int;

  Set<Object?> colOf(sqlite3.Database db, String table, String column) => db
      .select('SELECT "$column" FROM "$table"')
      .map((r) => r[column])
      .toSet();

  List<String> tableNames(sqlite3.Database db) => db
      .select("SELECT name FROM sqlite_master WHERE type='table' "
          "AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .map((r) => r['name'] as String)
      .toList();

  group('בנייה של תת-קבוצה חלקית', () {
    late SubsetBuildResult result;

    setUp(() {
      buildFullDb(at('full.db'), version: 7);
      result = const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('sub.db'),
        bookIds: {1, 2},
      );
    });

    test('טבלת book מכילה בדיוק את הספרים שנבחרו', () {
      on(at('sub.db'), (db) {
        expect(colOf(db, 'book', 'id'), {1, 2});
      });
    });

    test('טבלת line מכילה רק שורות של ספרים שנבחרו', () {
      on(at('sub.db'), (db) {
        expect(rows(db, 'line'), 6);
        expect(colOf(db, 'line', 'bookId'), {1, 2});
      });
    });

    test('הטבלאות הגלובליות נשמרות במלואן', () {
      // תכונת התכנון המרכזית: גיזום של author/tocText/category היה מפיל
      // את אילוצי ה-UNIQUE הגלובליים ומפצל את הספרייה מהאפסטרים.
      on(at('full.db'), (full) {
        on(at('sub.db'), (sub) {
          for (final t in const [
            'author',
            'tocText',
            'category',
            'category_closure',
          ]) {
            expect(rows(sub, t), rows(full, t), reason: 'טבלה גלובלית $t');
          }
        });
      });
    });

    test('קישור פנימי נשמר וקישורים חוצי-גבול מנותקים', () {
      on(at('sub.db'), (db) {
        expect(colOf(db, 'link', 'id'), {1},
            reason: '‏2 (1→3) ו-3 (4→2) חייבים להינתק');
      });
    });

    test('link_anchor של קישור שנותק נעלם איתו', () {
      // הצאצא נקבע לפי ההורה **שביעד**; עוגן ששרד בלי הקישור שלו היה
      // הפרת מפתח זר שהמסד לא היה תופס (foreign_keys כבוי בהעתקה).
      on(at('sub.db'), (db) {
        expect(colOf(db, 'link_anchor', 'linkId'), {1});
      });
    });

    test('version_line נשמרת רק לשורות ששרדו', () {
      on(at('sub.db'), (db) {
        expect(rows(db, 'version_line'), 6);
        expect(colOf(db, 'version_line', 'versionId'), {1, 2});
      });
    });

    test('schema_meta עוברת כמות שהיא עם db_version', () {
      // ה-preflight של PatchApplier קורא את השורה הזו; בלעדיה אין עדכון.
      on(at('sub.db'), (db) {
        final meta = {
          for (final r in db.select('SELECT key, value FROM schema_meta'))
            r['key'] as String: r['value'] as String,
        };
        expect(meta['db_version'], '7');
        expect(meta['db_schema_version'], '5');
      });
    });

    test('תוצאת הבנייה מדווחת גרסאות, ספירות וגודל', () {
      expect(result.dbVersion, 7);
      expect(result.schemaVersion, 5);
      expect(result.rowsCopied['book'], 2);
      expect(result.rowsCopied['line'], 6);
      expect(result.rowsCopied['link'], 1);
      expect(result.rowsCopied['link_anchor'], 1);
      expect(result.rowsCopied['version_line'], 6);
      expect(result.rowsCopied['author'], 2);
      expect(result.totalRows, greaterThan(0));
      expect(result.resultBytes, greaterThan(0));
      expect(result.resultBytes, File(at('sub.db')).lengthSync());
    });

    test('התוצאה עוברת בדיקת מפתח זר ושלמות', () {
      on(at('sub.db'), (db) {
        db.execute('PRAGMA foreign_keys = ON');
        expect(db.select('PRAGMA foreign_key_check'), isEmpty);
        expect(db.select('PRAGMA quick_check').first.values.first, 'ok');
      });
    });

    test('המקור אינו משתנה כלל', () {
      // המקור מחובר ב-mode=ro דווקא כדי שזה יהיה נכון. כתיבה אליו היא
      // ‏7.4GB שאין לשחזר בלי הורדה מחדש.
      final source = File(at('full.db'));
      final before = source.readAsBytesSync();
      final beforeStamp = source.lastModifiedSync();

      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('sub2.db'),
        bookIds: {3},
      );

      expect(source.readAsBytesSync(), before);
      expect(source.lastModifiedSync(), beforeStamp);
      expect(File('${at('full.db')}-wal').existsSync(), isFalse);
      expect(File('${at('full.db')}-journal').existsSync(), isFalse);
    });
  });

  group('מקרי קצה של הבחירה', () {
    test('בחירה ריקה מייצרת מסד בלי ספרים אך עם גלובליים שלמים', () {
      buildFullDb(at('full.db'));
      final r = const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('sub.db'),
        bookIds: const {},
      );
      expect(r.rowsCopied['book'], 0);
      expect(r.rowsCopied['line'], 0);
      expect(r.rowsCopied['link'], 0);
      on(at('sub.db'), (db) {
        expect(rows(db, 'category'), 3);
        expect(rows(db, 'author'), 2);
        expect(rows(db, 'schema_meta'), 2);
        db.execute('PRAGMA foreign_keys = ON');
        expect(db.select('PRAGMA foreign_key_check'), isEmpty);
      });
    });

    test('בחירת כל הספרים היא העתק חסר-אובדן', () {
      // העתקה מלאה שאינה זהה למקור פירושה שהמנוע מאבד שורות בשקט
      // בטבלה כלשהי — וזה הכשל שאין לו סימן.
      buildFullDb(at('full.db'));
      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('sub.db'),
        bookIds: {1, 2, 3, 4},
      );
      on(at('full.db'), (full) {
        on(at('sub.db'), (sub) {
          for (final t in tableNames(full)) {
            expect(rows(sub, t), rows(full, t), reason: 'טבלה $t');
          }
        });
      });
    });

    test('אינדקסים מהמקור קיימים בתוצאה', () {
      // האינדקסים נוצרים אחרי ההעתקה; באג בסדר הזה היה מייצר מסד
      // תקין-לכאורה שכל שאילתה בו סורקת טבלה.
      buildFullDb(at('full.db'));
      final src = sqlite3.sqlite3.open(at('full.db'));
      try {
        src.execute('CREATE INDEX idx_line_book ON line(bookId, lineIndex)');
        src.execute('CREATE INDEX idx_link_source ON link(sourceBookId)');
        src.execute('CREATE UNIQUE INDEX idx_book_title ON book(title)');
      } finally {
        src.close();
      }

      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('sub.db'),
        bookIds: {1, 2},
      );

      Set<String> indexes(sqlite3.Database db) => db
          .select("SELECT name FROM sqlite_master WHERE type='index'")
          .map((r) => r['name'] as String)
          .toSet();

      on(at('full.db'), (full) {
        on(at('sub.db'), (sub) {
          expect(indexes(sub), indexes(full));
        });
      });
    });
  });

  group('כשלים', () {
    test('קובץ יעד קיים הוא שגיאה ולא דריסה', () {
      // דריסה הייתה מוחקת ספרייה עובדת של המשתמש.
      buildFullDb(at('full.db'));
      File(at('sub.db')).writeAsStringSync('ספרייה קיימת');
      expect(
        () => const SubsetBuilder().build(
          sourcePath: at('full.db'),
          targetPath: at('sub.db'),
          bookIds: {1},
        ),
        throwsA(isA<SubsetBuildException>()),
      );
      expect(File(at('sub.db')).readAsStringSync(), 'ספרייה קיימת',
          reason: 'הקובץ הקיים לא נגעו בו');
    });

    test('מסד מקור חסר הוא שגיאה', () {
      expect(
        () => const SubsetBuilder().build(
          sourcePath: at('missing.db'),
          targetPath: at('sub.db'),
          bookIds: {1},
        ),
        throwsA(isA<SubsetBuildException>()),
      );
      expect(File(at('sub.db')).existsSync(), isFalse);
    });

    test('טבלה שאינה מסווגת עוצרת את הבנייה ומוחקת את היעד', () {
      // ההגנה מפני סכמה שהתקדמה: טבלה חדשה שלא סווגה חייבת להפיל את
      // הבנייה בקול, ולא להיעלם בשקט מהספרייה.
      buildFullDb(at('full.db'));
      final src = sqlite3.sqlite3.open(at('full.db'));
      try {
        src.execute('CREATE TABLE mystery_table (id INTEGER PRIMARY KEY)');
      } finally {
        src.close();
      }

      expect(
        () => const SubsetBuilder().build(
          sourcePath: at('full.db'),
          targetPath: at('sub.db'),
          bookIds: {1, 2},
        ),
        throwsA(isA<SubsetBuildException>().having(
          (e) => e.message,
          'message',
          contains('mystery_table'),
        )),
      );
      expect(File(at('sub.db')).existsSync(), isFalse,
          reason: 'תת-קבוצה חלקית מסוכנת יותר מכלום');
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'fixtures.dart';

/// בדיקות ל-[LibraryCatalog], ל-`readCatalogFromPath` ול-`readLibraryStats`
/// — עץ הקטגוריות והספרים שמסך הבחירה מציג, בלי לגעת בשום תוכן ספרים.
void main() {
  late Directory dir;

  setUp(() => dir = createTempDir('catalog'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String at(String name) => p.join(dir.path, name);

  /// בונה מסד מדומה עם רק schema_meta/category/book/line — כל מה
  /// שהקטלוג צריך, בלי שאר טבלאות ה-fixture המלא. ה-DDL נלקח מ-
  /// [kFixtureSchema] כדי שהעמודות יישארו זהות לסכמה האמיתית.
  sqlite3.Database openMiniDb(String path) {
    final db = sqlite3.sqlite3.open(path);
    const wanted = {'schema_meta', 'category', 'book', 'line'};
    for (final ddl in kFixtureSchema) {
      final name = RegExp(r'CREATE TABLE (\w+)').firstMatch(ddl)!.group(1)!;
      if (wanted.contains(name)) db.execute(ddl);
    }
    return db;
  }

  group('בניית העץ', () {
    test('childrenOf ו-booksOf ממוינים כמו שאוצריא מציגה', () {
      buildFullDb(at('full.db'));
      final catalog = readCatalogFromPath(at('full.db'));

      expect(catalog.roots.map((c) => c.id), [1]);
      expect(catalog.childrenOf[1]!.map((c) => c.id), [10, 11]);
      expect(catalog.booksOf[10]!.map((b) => b.title), ['ספר 1', 'ספר 2']);
      expect(catalog.booksOf[11]!.map((b) => b.title), ['ספר 3', 'ספר 4']);
      expect(catalog.parentOf, {1: null, 10: 1, 11: 1});
    });

    test('קטגוריות ממוינות לפי orderIndex, ובשוויון — לפי כותרת', () {
      final db = openMiniDb(at('order.db'));
      db.execute("INSERT INTO category VALUES "
          "(1, NULL, 'שורש', 0, 1), "
          "(2, 1, 'ב', 1, 5), "
          "(3, 1, 'א', 1, 5), "
          "(4, 1, 'ת', 1, 1)");
      db.close();

      final catalog = readCatalogFromPath(at('order.db'));
      // ‏4 קודם (orderIndex=1), ואז 3,2 לפי כותרת כי שניהם orderIndex=5.
      expect(catalog.childrenOf[1]!.map((c) => c.id), [4, 3, 2]);
    });

    test('ספרים ממוינים לפי כותרת בלבד, בלי קשר לסדר ההוספה', () {
      final db = openMiniDb(at('books.db'));
      db.execute("INSERT INTO category VALUES (1, NULL, 'שורש', 0, 1)");
      db.execute("INSERT INTO book VALUES "
          "(1, 1, 'ג', 0), (2, 1, 'א', 0), (3, 1, 'ב', 0)");
      db.close();

      final catalog = readCatalogFromPath(at('books.db'));
      expect(catalog.booksOf[1]!.map((b) => b.title), ['א', 'ב', 'ג']);
    });

    test('הורה שאינו קיים במסד הופך את הקטגוריה לשורש', () {
      // ענף גזום: הקטגוריה חייבת להישאר נגישה כשורש, אחרת הייתה נעלמת
      // מהעץ בלי סימן.
      final db = openMiniDb(at('orphan.db'));
      db.execute("INSERT INTO category VALUES "
          "(1, NULL, 'שורש', 0, 1), "
          "(2, 999, 'יתום', 1, 1)");
      db.close();

      final catalog = readCatalogFromPath(at('orphan.db'));
      expect(catalog.roots.map((c) => c.id).toSet(), {1, 2});
      expect(catalog.childrenOf.containsKey(999), isFalse);
    });
  });

  group('descendantsOf / booksUnder', () {
    test('descendantsOf כולל את עצמה ופועל בכמה רמות עומק', () {
      final db = openMiniDb(at('depth.db'));
      db.execute("INSERT INTO category VALUES "
          "(1, NULL, 'שורש', 0, 1), "
          "(2, 1, 'ילד', 1, 1), "
          "(3, 2, 'נכד', 2, 1)");
      db.close();

      final catalog = readCatalogFromPath(at('depth.db'));
      expect(catalog.descendantsOf(1), {1, 2, 3});
      expect(catalog.descendantsOf(2), {2, 3});
      expect(catalog.descendantsOf(3), {3});
    });

    test('booksUnder אוסף ספרים מכל עומק, כולל הקטגוריה עצמה', () {
      final db = openMiniDb(at('under.db'));
      db.execute("INSERT INTO category VALUES "
          "(1, NULL, 'שורש', 0, 1), "
          "(2, 1, 'ילד', 1, 1), "
          "(3, 2, 'נכד', 2, 1)");
      db.execute("INSERT INTO book VALUES "
          "(1, 1, 'בשורש', 0), (2, 2, 'בילד', 0), (3, 3, 'בנכד', 0)");
      db.close();

      final catalog = readCatalogFromPath(at('under.db'));
      expect(catalog.booksUnder(1).map((b) => b.id).toSet(), {1, 2, 3});
      expect(catalog.booksUnder(2).map((b) => b.id).toSet(), {2, 3});
      expect(catalog.booksUnder(3).map((b) => b.id).toSet(), {3});
    });
  });

  group('readLibraryStats', () {
    test('סופרת שורות וקוראת גרסאות מ-schema_meta', () {
      buildFullDb(at('full.db'), version: 9, schemaVersion: 5);
      final db =
          sqlite3.sqlite3.open(at('full.db'), mode: sqlite3.OpenMode.readOnly);
      try {
        final stats = readLibraryStats(db, fileBytes: 123);
        expect(stats.dbVersion, 9);
        expect(stats.schemaVersion, 5);
        expect(stats.bookCount, 4);
        expect(stats.categoryCount, 3);
        expect(stats.lineCount, 12);
        expect(stats.fileBytes, 123);
      } finally {
        db.close();
      }
    });

    test('מסד בלי שורות ב-schema_meta מחזיר גרסאות null וספירות אפס', () {
      final db = openMiniDb(at('nometa.db'));
      db.close();
      final ro = sqlite3.sqlite3
          .open(at('nometa.db'), mode: sqlite3.OpenMode.readOnly);
      try {
        final stats = readLibraryStats(ro, fileBytes: 0);
        expect(stats.dbVersion, isNull);
        expect(stats.schemaVersion, isNull);
        expect(stats.bookCount, 0);
        expect(stats.categoryCount, 0);
        expect(stats.lineCount, 0);
      } finally {
        ro.close();
      }
    });
  });

  group('מסד ריק', () {
    test('קטלוג ממסד ריק לגמרי שווה במבנהו ל-LibraryCatalog.empty', () {
      final db = openMiniDb(at('empty.db'));
      db.close();

      final catalog = readCatalogFromPath(at('empty.db'));
      expect(catalog.roots, isEmpty);
      expect(catalog.categories, isEmpty);
      expect(catalog.books, isEmpty);
      expect(catalog.bookCount, 0);
      expect(catalog.categoryCount, 0);
      expect(catalog.childrenOf, isEmpty);
      expect(catalog.booksOf, isEmpty);
    });
  });
}

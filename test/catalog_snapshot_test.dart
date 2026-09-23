import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:path/path.dart' as p;

import 'fixtures.dart';

/// בדיקות לתצלום הקטלוג (JSON) ולאומדני הגודל שבעץ.
///
/// התצלום הוא הדרך היחידה להחזיר ספר שנמחק: הוא נלקח כשהמסד עוד שלם,
/// ומה שלא שרד את הסבב-חזרה שלו פשוט לא יוצע למשתמש לעולם.
void main() {
  CatalogCategory cat(int id, int? parentId, {int orderIndex = 1}) =>
      CatalogCategory(
        id: id,
        parentId: parentId,
        title: 'קטגוריה "$id"',
        level: parentId == null ? 0 : 1,
        orderIndex: orderIndex,
      );

  CatalogBook book(int id, int categoryId, int lines) => CatalogBook(
        id: id,
        categoryId: categoryId,
        title: 'ספר $id',
        totalLines: lines,
      );

  // 1 → 10 (ספרים 1,2), 11 → 12 (ספר 3); ו-50 יתום שהורהו אינו קיים.
  final catalog = LibraryCatalog(
    [
      cat(1, null),
      cat(10, 1, orderIndex: 2),
      cat(11, 1, orderIndex: 1),
      cat(12, 11),
      cat(50, 999),
    ],
    [book(1, 10, 100), book(2, 10, 300), book(3, 12, 1000), book(4, 50, 7)],
    bytesPerLine: 40.5,
    dbVersion: 17,
  );

  group('JSON', () {
    test('סבב-חזרה שומר את כל השדות ואת מבנה העץ', () {
      final text = jsonEncode(catalog.toJson());
      final back = LibraryCatalog.fromJson(
        jsonDecode(text) as Map<String, dynamic>,
      );

      expect(back.dbVersion, 17);
      expect(back.bytesPerLine, 40.5);
      expect(back.categoryCount, catalog.categoryCount);
      expect(back.bookCount, catalog.bookCount);
      for (final c in catalog.categories) {
        final other = back.categories.singleWhere((x) => x.id == c.id);
        expect(other.parentId, c.parentId);
        expect(other.title, c.title);
        expect(other.level, c.level);
        expect(other.orderIndex, c.orderIndex);
      }
      for (final b in catalog.books) {
        final other = back.bookById(b.id)!;
        expect(other.categoryId, b.categoryId);
        expect(other.title, b.title);
        expect(other.totalLines, b.totalLines);
      }
      expect(back.roots.map((c) => c.id), catalog.roots.map((c) => c.id));
      expect(back.childrenOf[1]!.map((c) => c.id), [11, 10]);
      expect(back.bytesUnder(1), catalog.bytesUnder(1));
    });

    test('הפורמט קומפקטי — שורה היא מערך, לא אובייקט', () {
      final json = catalog.toJson();
      expect(json['format'], LibraryCatalog.jsonFormat);
      expect(json['version'], LibraryCatalog.jsonVersion);
      expect((json['books'] as List).first, [1, 10, 'ספר 1', 100]);
      expect(
          (json['categories'] as List).first, [1, null, 'קטגוריה "1"', 0, 1]);
    });

    test('קטלוג ריק עובר סבב-חזרה', () {
      final back = LibraryCatalog.fromJson(
        jsonDecode(jsonEncode(LibraryCatalog.empty.toJson()))
            as Map<String, dynamic>,
      );
      expect(back.books, isEmpty);
      expect(back.categories, isEmpty);
      expect(back.bytesPerLine, 0);
      expect(back.dbVersion, isNull);
    });

    Map<String, dynamic> valid() =>
        jsonDecode(jsonEncode(catalog.toJson())) as Map<String, dynamic>;

    test('פורמט זר נדחה', () {
      expect(
        () => LibraryCatalog.fromJson({...valid(), 'format': 'other'}),
        throwsFormatException,
      );
      expect(
        () => LibraryCatalog.fromJson(const {'id': 'pc', 'label': 'x'}),
        throwsFormatException,
        reason: 'קובץ פרופיל אינו תצלום',
      );
    });

    test('גרסה חדשה מדי, חסרה או פגומה נדחית', () {
      expect(
        () => LibraryCatalog.fromJson(
            {...valid(), 'version': LibraryCatalog.jsonVersion + 1}),
        throwsFormatException,
      );
      expect(
        () => LibraryCatalog.fromJson({...valid()}..remove('version')),
        throwsFormatException,
      );
      expect(
        () => LibraryCatalog.fromJson({...valid(), 'version': '1'}),
        throwsFormatException,
      );
    });

    test('שורה פגומה נדחית ולא מושמטת בשקט', () {
      expect(
        () => LibraryCatalog.fromJson({
          ...valid(),
          'books': [
            [1, 10, 'ספר'],
          ],
        }),
        throwsFormatException,
        reason: 'שורה קצרה',
      );
      expect(
        () => LibraryCatalog.fromJson({
          ...valid(),
          'books': [
            ['1', 10, 'ספר', 0],
          ],
        }),
        throwsFormatException,
        reason: 'מזהה שאינו מספר',
      );
      expect(
        () => LibraryCatalog.fromJson({
          ...valid(),
          'categories': [
            [1, null, 5, 0, 1],
          ],
        }),
        throwsFormatException,
        reason: 'כותרת שאינה מחרוזת',
      );
      expect(
        () => LibraryCatalog.fromJson({...valid()}..remove('books')),
        throwsFormatException,
      );
    });
  });

  group('גדלים', () {
    test('ספר: שורות × כיול × מקדם הביטחון של הפותר', () {
      final b = catalog.bookById(2)!;
      expect(
        catalog.estimatedBytesOf(b),
        (300 * 40.5 * SubsetResolver.sizeSafetyFactor).round(),
      );
    });

    test('קטגוריה: סכום כל הספרים שתחתיה בכל עומק', () {
      expect(catalog.linesUnder(10), 400);
      expect(catalog.linesUnder(12), 1000);
      expect(catalog.linesUnder(11), 1000);
      expect(catalog.linesUnder(1), 1400);
      expect(catalog.linesUnder(50), 7, reason: 'יתום נספר כשורש');
      expect(catalog.linesUnder(12345), 0);
      expect(
        catalog.bytesUnder(1),
        (1400 * 40.5 * SubsetResolver.sizeSafetyFactor).round(),
      );
    });

    test('מיון ילדים לפי גודל נשען על bytesUnder', () {
      final bySize = [...catalog.childrenOf[1]!]
        ..sort((a, b) => catalog.bytesUnder(b.id) - catalog.bytesUnder(a.id));
      expect(bySize.map((c) => c.id), [11, 10]);
    });

    test('בלי כיול כל האומדנים הם אפס, וכיול לא תקין מתאפס', () {
      final plain = LibraryCatalog(catalog.categories, catalog.books);
      expect(plain.bytesUnder(1), 0);
      expect(plain.linesUnder(1), 1400, reason: 'השורות אינן תלויות בכיול');
      expect(
        LibraryCatalog(const [], const [], bytesPerLine: -3).bytesPerLine,
        0,
      );
      expect(
        LibraryCatalog(const [], const [], bytesPerLine: double.nan)
            .bytesPerLine,
        0,
      );
    });

    test('withBytesPerLine מחליף רק את הכיול', () {
      final other = catalog.withBytesPerLine(10);
      expect(other.bytesPerLine, 10);
      expect(other.dbVersion, 17);
      expect(other.bookCount, catalog.bookCount);
      expect(other.bytesUnder(10),
          (400 * 10 * SubsetResolver.sizeSafetyFactor).round());
    });
  });

  group('readCatalog', () {
    late Directory dir;
    setUp(() => dir = createTempDir('catalog_snapshot'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('קורא גרסה וכיול מהמסד, והכיול אינו שלילי', () {
      final path = p.join(dir.path, 'full.db');
      buildFullDb(path, version: 9);
      final read = readCatalogFromPath(path);

      expect(read.dbVersion, 9);
      // מסד ה-fixture קטן מהרצפה הגלובלית — הכיול מתאפס ולא נהיה שלילי.
      expect(read.bytesPerLine, 0);
      expect(read.linesUnder(1), 12);
      expect(read.linesUnder(10), 6);
    });

    test('סבב-חזרה של קטלוג שנקרא ממסד', () {
      final path = p.join(dir.path, 'full.db');
      buildFullDb(path);
      final read = readCatalogFromPath(path);
      final back = LibraryCatalog.fromJson(
        jsonDecode(jsonEncode(read.toJson())) as Map<String, dynamic>,
      );
      expect(back.books.map((b) => b.id).toSet(), {1, 2, 3, 4});
      expect(back.parentOf, read.parentOf);
    });
  });

  group('ProfileStore — תצלום קטלוג', () {
    late Directory dir;
    late ProfileStore store;
    setUp(() {
      dir = createTempDir('snapshot_store');
      store = ProfileStore(dir.path);
    });
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('שמירה וטעינה', () {
      final profile = store.create('המחשב בבית');
      expect(store.hasCatalogSnapshot(profile.id), isFalse);
      expect(store.loadCatalogSnapshot(profile.id), isNull);

      store.saveCatalogSnapshot(profile.id, catalog);

      expect(store.hasCatalogSnapshot(profile.id), isTrue);
      final back = store.loadCatalogSnapshot(profile.id)!;
      expect(back.bookCount, catalog.bookCount);
      expect(back.bytesPerLine, 40.5);
      expect(
        dir.listSync().where((e) => e.path.endsWith('.tmp')),
        isEmpty,
      );
    });

    test('התצלום אינו נקרא כפרופיל פגום ב-loadAll', () {
      final profile = store.create('מחשב');
      store.saveCatalogSnapshot(profile.id, catalog);

      final corrupt = <String>[];
      final all = store.loadAll(onCorrupt: (path, _) => corrupt.add(path));
      expect(all.map((x) => x.id), [profile.id]);
      expect(corrupt, isEmpty);
    });

    test('תצלום פגום מחזיר null ואינו זורק', () {
      final profile = store.create('מחשב');
      store.saveCatalogSnapshot(profile.id, catalog);
      final file = dir
          .listSync()
          .whereType<File>()
          .singleWhere((f) => f.path.endsWith('.catalog'));
      file.writeAsStringSync('{"format": "otzaria-subset-catalog", "vers');

      expect(store.loadCatalogSnapshot(profile.id), isNull);
    });

    test('מחיקת פרופיל מוחקת את התצלום שלו', () {
      final profile = store.create('מחשב');
      store.saveCatalogSnapshot(profile.id, catalog);

      expect(store.delete(profile.id), isTrue);
      expect(store.hasCatalogSnapshot(profile.id), isFalse);
      expect(store.deleteCatalogSnapshot(profile.id), isFalse);
    });
  });
}

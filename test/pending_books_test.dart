import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'fixtures.dart';

/// בדיקות לספרים ממתינים שנשמרים בפרופיל (§5 ב-AGENTS.md).
///
/// ספר ממתין אינו במסד, ולכן הפרופיל הוא המקום היחיד שזוכר אותו. שלושה
/// דברים נבדקים: הוא שורד שמירה וטעינה, הוא מצטבר בין עדכונים ומתנקה
/// בבנייה מלאה, ו-patch שנושא לו שורות אינו מכניס אותו חצי-מלא.
void main() {
  const filterReport = PatchFilterReport(
    kept: {},
    dropped: {},
    synthesizedDeletes: {},
  );

  group('SubsetProfile', () {
    test('סבב-חזרה ב-JSON', () {
      const profile = SubsetProfile(
        id: 'pc',
        label: 'המחשב בבית',
        pendingBookIds: {9, 3},
      );
      final back = SubsetProfile.fromJson(
        jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
      );
      expect(back.pendingBookIds, {3, 9});
      expect(profile.toJson()['pendingBookIds'], [3, 9]);
    });

    test('קובץ מגרסה קודמת, בלי השדה, נטען עם אפס ממתינים', () {
      final back = SubsetProfile.fromJson(const {'id': 'pc', 'label': 'x'});
      expect(back.pendingBookIds, isEmpty);
      expect(
        SubsetProfile.fromJson(const {'id': 'pc', 'pendingBookIds': 'bad'})
            .pendingBookIds,
        isEmpty,
      );
    });

    test('copyWith: null משאיר, קבוצה ריקה מנקה', () {
      const profile =
          SubsetProfile(id: 'pc', label: 'x', pendingBookIds: {1, 2});
      expect(profile.copyWith(label: 'y').pendingBookIds, {1, 2});
      expect(
          profile.copyWith(pendingBookIds: const {}).pendingBookIds, isEmpty);
      expect(profile.copyWith(pendingBookIds: {5}).pendingBookIds, {5});
    });

    test('נשמר ונטען דרך ProfileStore', () {
      final dir = createTempDir('pending_store');
      try {
        final store = ProfileStore(dir.path);
        final created = store.create('מחשב');
        store.save(created.copyWith(pendingBookIds: {4, 8}));
        expect(store.load(created.id)!.pendingBookIds, {4, 8});
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('profileAfter', () {
    test('בנייה מחדש ממסד מלא מנקה את הממתינים', () {
      const profile = SubsetProfile(
        id: 'pc',
        label: 'x',
        spec: SubsetSpec(categoryIds: {10}),
        pendingBookIds: {3, 4},
      );
      const result = SubsetRebuildResult(
        dbVersion: 5,
        schemaVersion: 5,
        subsetHash: 'subset:v5:x',
        bookIds: {1, 2, 3, 4},
        keepCategories: {1, 10},
        resultBytes: 1,
        indexInvalidation: null,
      );

      final after = const SubsetRebuilder()
          .profileAfter(profile, result, categoriesPruned: true);
      expect(after.pendingBookIds, isEmpty);
    });

    test('עדכון מצרף ממתינים חדשים ומוריד את מה שנכנס או הוחרג', () {
      const profile = SubsetProfile(
        id: 'pc',
        label: 'x',
        spec: SubsetSpec(categoryIds: {10}, excludeBookIds: {8}),
        // ‏3 נכנס בינתיים, 8 הוחרג, 5 עדיין ממתין ואינו ב-patch הזה.
        pendingBookIds: {3, 5, 8},
      );
      const result = SubsetUpdateResult(
        toVersion: 2,
        subsetHash: 'subset:v5:new',
        bookIds: {1, 2, 3},
        pendingAcquisition: {6},
        filterReport: filterReport,
      );

      final after =
          const SubsetUpdater().profileAfter(profile, result, schemaVersion: 5);
      expect(after.pendingBookIds, {5, 6});
    });
  });

  group('SubsetUpdater עם ממתינים ידועים', () {
    late Directory dir;
    setUp(() => dir = createTempDir('pending_updater'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    String at(String name) => p.join(dir.path, name);
    const spec = SubsetSpec(categoryIds: {10});

    DeltaManifest manifest(int from, int to) => DeltaManifest(
          fromVersion: from,
          toVersion: to,
          fromSchemaVersion: 5,
          toSchemaVersion: 5,
          patchFormatVersion: 4,
          fromContentHash: 'x',
          toContentHash: 'y',
          patchFiles: const [],
        );

    int countRows(String path, String sql) {
      final db = sqlite3.sqlite3.open(path, mode: sqlite3.OpenMode.readOnly);
      try {
        return db.select(sql).first.values.first as int;
      } finally {
        db.close();
      }
    }

    test('patch שנושא שורות לספר ממתין אינו מכניס אותו חצי-מלא', () {
      buildFullDb(at('full.db'), version: 1);
      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('subset.db'),
        bookIds: {1, 2},
      );

      // עדכון ראשון: ספר 3 עובר לקטגוריה שנבחרה — שורת book בלבד.
      buildPatchDb(at('p1.db'), fromVersion: 1, toVersion: 2, mutate: (db) {
        db.execute("INSERT INTO upsert_book VALUES (3, 10, 'ספר 3', 3)");
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
      });
      final first = const SubsetUpdater().applyPatch(
        subsetPath: at('subset.db'),
        patchPath: at('p1.db'),
        manifest: manifest(1, 2),
        spec: spec,
        workDir: at('work'),
        categoriesPruned: false,
      );
      expect(first.pendingAcquisition, {3});
      final profile = const SubsetUpdater().profileAfter(
        const SubsetProfile(id: 'pc', label: 'x', spec: spec),
        first,
        schemaVersion: 5,
      );
      expect(profile.pendingBookIds, {3});

      // עדכון שני: שורה אחת של ספר 3 נערכה. זה כל מה שה-patch נושא ממנו.
      buildPatchDb(at('p2.db'), fromVersion: 2, toVersion: 3, mutate: (db) {
        db.execute("INSERT INTO upsert_book VALUES (3, 10, 'ספר 3', 3)");
        db.execute("INSERT INTO upsert_line VALUES (301, 3, 1, 'נערכה', 6)");
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','3')");
      });
      final second = const SubsetUpdater().applyPatch(
        subsetPath: at('subset.db'),
        patchPath: at('p2.db'),
        manifest: manifest(2, 3),
        spec: spec,
        workDir: at('work'),
        categoriesPruned: false,
        pendingBookIds: profile.pendingBookIds,
      );

      expect(second.pendingAcquisition, contains(3));
      expect(second.bookIds, isNot(contains(3)));
      expect(countRows(at('subset.db'), 'SELECT COUNT(*) FROM book'), 2);
      expect(
        countRows(
            at('subset.db'), 'SELECT COUNT(*) FROM line WHERE bookId = 3'),
        0,
        reason: 'שורה אחת מתוך שלוש הייתה ספר שנראה קיים ונפתח חסר',
      );
      expect(
        const SubsetUpdater()
            .profileAfter(profile, second, schemaVersion: 5)
            .pendingBookIds,
        {3},
      );
    });
  });
}

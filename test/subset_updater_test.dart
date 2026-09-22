import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'fixtures.dart';

/// בדיקות ה-orchestrator.
///
/// הנושא המרכזי כאן אינו "האם העדכון עובד" — לזה יש את מבחן השקילות —
/// אלא **מה קורה כשהוא נכשל**. כל כשל חייב להשאיר את המסד של המשתמש
/// בדיוק כשהיה, ולא להשאיר קבצים זמניים שיתפסו מקום או יבלבלו ריצה באה.
void main() {
  late Directory dir;

  setUp(() => dir = createTempDir('updater'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String at(String name) => p.join(dir.path, name);
  String work() => p.join(dir.path, 'work');

  const spec = SubsetSpec(categoryIds: {10});

  DeltaManifest manifest({int from = 1, int to = 2}) => DeltaManifest(
        fromVersion: from,
        toVersion: to,
        fromSchemaVersion: 5,
        toSchemaVersion: 5,
        patchFormatVersion: 4,
        fromContentHash: 'x',
        toContentHash: 'y',
        patchFiles: const [],
      );

  /// בונה תת-קבוצה של ספרים 1,2 ומחזיר את נתיבה.
  String buildSubset() {
    buildFullDb(at('full.db'), version: 1);
    const SubsetBuilder().build(
      sourcePath: at('full.db'),
      targetPath: at('subset.db'),
      bookIds: {1, 2},
    );
    return at('subset.db');
  }

  String hashOf(String path) {
    final db = sqlite3.sqlite3.open(path, mode: sqlite3.OpenMode.readOnly);
    try {
      return const SubsetHasher().compute(db, schemaVersion: 5);
    } finally {
      db.close();
    }
  }

  int countRows(String path, String table) {
    final db = sqlite3.sqlite3.open(path, mode: sqlite3.OpenMode.readOnly);
    try {
      return db.select('SELECT COUNT(*) c FROM $table').first['c'] as int;
    } finally {
      db.close();
    }
  }

  /// כמה קבצים נשארו בתיקיית העבודה. חייב להיות 0 אחרי כל ריצה —
  /// מוצלחת או כושלת.
  int leftoverWorkFiles() {
    final d = Directory(work());
    if (!d.existsSync()) return 0;
    return d.listSync().whereType<File>().length;
  }

  group('מסלול מוצלח', () {
    test('עדכון תוכן מעדכן גרסה, hash ושורות', () {
      final subset = buildSubset();
      final before = hashOf(subset);

      buildPatchDb(at('patch.db'), fromVersion: 1, toVersion: 2,
          mutate: (db) {
        db.execute("INSERT INTO upsert_line VALUES (100, 1, 0, 'עודכן', 6)");
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
      });

      final result = const SubsetUpdater().applyPatch(
        subsetPath: subset,
        patchPath: at('patch.db'),
        manifest: manifest(),
        spec: spec,
        workDir: work(),
        categoriesPruned: false,
      );

      expect(result.toVersion, 2);
      expect(result.bookIds, {1, 2});
      expect(result.pendingAcquisition, isEmpty);
      expect(result.subsetHash, isNot(before));
      expect(SubsetHasher.isSubsetHash(result.subsetHash), isTrue);
      // ה-hash שהוחזר הוא של המסד שבמקום, לא של ההעתק שנמחק.
      expect(hashOf(subset), result.subsetHash);
      expect(leftoverWorkFiles(), 0);
    });

    test('שורה חדשה נכנסת, שורה של ספר שלא נבחר לא', () {
      final subset = buildSubset();
      final linesBefore = countRows(subset, 'line');

      buildPatchDb(at('patch.db'), fromVersion: 1, toVersion: 2,
          mutate: (db) {
        db.execute("INSERT INTO upsert_line VALUES (103, 1, 3, 'חדשה', 6)");
        db.execute("INSERT INTO upsert_line VALUES (303, 3, 3, 'בחוץ', 6)");
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
      });

      const SubsetUpdater().applyPatch(
        subsetPath: subset,
        patchPath: at('patch.db'),
        manifest: manifest(),
        spec: spec,
        workDir: work(),
        categoriesPruned: false,
      );

      expect(countRows(subset, 'line'), linesBefore + 1,
          reason: 'רק השורה של הספר שנבחר נכנסה');
    });

    test('ספר ותיק שנכנס לבחירה מדווח כממתין להבאה', () {
      final subset = buildSubset();
      buildPatchDb(at('patch.db'), fromVersion: 1, toVersion: 2,
          mutate: (db) {
        db.execute("INSERT INTO upsert_book VALUES (3, 10, 'ספר 3', 3)");
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
      });

      final result = const SubsetUpdater().applyPatch(
        subsetPath: subset,
        patchPath: at('patch.db'),
        manifest: manifest(),
        spec: spec,
        workDir: work(),
        categoriesPruned: false,
      );

      // הדיווח הוא כל העניין: המשתמש ביקש ספר ולא קיבל אותו, וזה חייב
      // להגיע אליו ולא להישאר בלוג.
      expect(result.hasPendingAcquisition, isTrue);
      expect(result.pendingAcquisition, {3});
      expect(countRows(subset, 'book'), 2, reason: 'ספר 3 לא נכנס חצי-ריק');
    });

    test('hash תואם עובר את בדיקת המצב הקודם', () {
      final subset = buildSubset();
      final recorded = hashOf(subset);
      buildPatchDb(at('patch.db'), fromVersion: 1, toVersion: 2,
          mutate: (db) {
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
      });

      expect(
        () => const SubsetUpdater().applyPatch(
          subsetPath: subset,
          patchPath: at('patch.db'),
          manifest: manifest(),
          spec: spec,
          workDir: work(),
          categoriesPruned: false,
          expectedHash: recorded,
        ),
        returnsNormally,
      );
    });
  });

  group('כשלים — המסד חייב להישאר כשהיה', () {
    test('hash שאינו תואם עוצר את העדכון', () {
      final subset = buildSubset();
      final before = hashOf(subset);
      buildPatchDb(at('patch.db'), fromVersion: 1, toVersion: 2,
          mutate: (db) {
        db.execute("INSERT INTO upsert_line VALUES (100, 1, 0, 'עודכן', 6)");
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
      });

      expect(
        () => const SubsetUpdater().applyPatch(
          subsetPath: subset,
          patchPath: at('patch.db'),
          manifest: manifest(),
          spec: spec,
          workDir: work(),
          categoriesPruned: false,
          expectedHash: 'subset:v5:deadbeef',
        ),
        throwsA(isA<SubsetUpdateException>()),
      );
      expect(hashOf(subset), before, reason: 'המסד לא נגע');
      expect(leftoverWorkFiles(), 0);
    });

    test('patch עם מיגרציות נדחה והמסד לא משתנה', () {
      final subset = buildSubset();
      final before = hashOf(subset);
      buildPatchDb(at('patch.db'), fromVersion: 1, toVersion: 2,
          mutate: (db) {
        db.execute("INSERT INTO migrations VALUES (1, 'ALTER TABLE book "
            "ADD COLUMN whatever TEXT')");
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
      });

      expect(
        () => const SubsetUpdater().applyPatch(
          subsetPath: subset,
          patchPath: at('patch.db'),
          manifest: manifest(),
          spec: spec,
          workDir: work(),
          categoriesPruned: false,
        ),
        throwsA(isA<PatchFilterException>()),
      );
      expect(hashOf(subset), before);
      expect(leftoverWorkFiles(), 0);
    });

    test('גרסה מקומית שאינה תואמת את המניפסט נדחית ב-preflight', () {
      final subset = buildSubset();
      final before = hashOf(subset);
      // ה-patch מצהיר על מעבר 7→8 בזמן שהמסד בגרסה 1.
      buildPatchDb(at('patch.db'), fromVersion: 7, toVersion: 8,
          mutate: (db) {
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','8')");
      });

      expect(
        () => const SubsetUpdater().applyPatch(
          subsetPath: subset,
          patchPath: at('patch.db'),
          manifest: manifest(from: 7, to: 8),
          spec: spec,
          workDir: work(),
          categoriesPruned: false,
        ),
        throwsA(isA<PatchApplyException>()),
      );
      expect(hashOf(subset), before);
      expect(leftoverWorkFiles(), 0);
    });

    test('מסד חלקי חסר', () {
      expect(
        () => const SubsetUpdater().applyPatch(
          subsetPath: at('nope.db'),
          patchPath: at('nope-patch.db'),
          manifest: manifest(),
          spec: spec,
          workDir: work(),
          categoriesPruned: false,
        ),
        throwsA(isA<SubsetUpdateException>()),
      );
    });

    test('קובץ patch חסר', () {
      final subset = buildSubset();
      expect(
        () => const SubsetUpdater().applyPatch(
          subsetPath: subset,
          patchPath: at('nope-patch.db'),
          manifest: manifest(),
          spec: spec,
          workDir: work(),
          categoriesPruned: false,
        ),
        throwsA(isA<SubsetUpdateException>()),
      );
    });

    test('גיבוי .bak אינו נשאר אחרי הצלחה', () {
      final subset = buildSubset();
      buildPatchDb(at('patch.db'), fromVersion: 1, toVersion: 2,
          mutate: (db) {
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
      });
      const SubsetUpdater().applyPatch(
        subsetPath: subset,
        patchPath: at('patch.db'),
        manifest: manifest(),
        spec: spec,
        workDir: work(),
        categoriesPruned: false,
      );
      expect(File('$subset.bak').existsSync(), isFalse);
    });
  });

  group('profileAfter', () {
    test('מעדכן גרסה, hash ותאריך ושומר את השאר', () {
      const profile = SubsetProfile(
        id: 'pc',
        label: 'המחשב בבית',
        spec: spec,
        dbVersion: 1,
        subsetHash: 'subset:v5:old',
        dbPath: r'C:\x\seforim.db',
        severedLinkCount: 42,
      );
      const result = SubsetUpdateResult(
        toVersion: 2,
        subsetHash: 'subset:v5:new',
        bookIds: {1, 2},
        pendingAcquisition: {},
        filterReport: PatchFilterReport(
          kept: {},
          dropped: {},
          synthesizedDeletes: {},
        ),
      );

      final after = const SubsetUpdater()
          .profileAfter(profile, result, schemaVersion: 5);

      expect(after.dbVersion, 2);
      expect(after.schemaVersion, 5);
      expect(after.subsetHash, 'subset:v5:new');
      expect(after.lastAppliedAt, isNotNull);
      // מה שלא נוגע לעדכון חייב לעבור כמות שהוא.
      expect(after.id, 'pc');
      expect(after.label, 'המחשב בבית');
      expect(after.dbPath, r'C:\x\seforim.db');
      expect(after.severedLinkCount, 42);
      expect(after.spec, spec);
    });
  });
}

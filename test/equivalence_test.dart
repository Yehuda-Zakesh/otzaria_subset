import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'fixtures.dart';

/// **מבחן השקילות — הבדיקה שקובעת אם הפרויקט עובד.**
///
/// הטענה שצריך להוכיח היא שסינון patch שקול לגיזום אחרי החלה:
///
/// ```
/// subset_K(apply(patch, full))  ==  apply(filter_K(patch), subset_K(full))
/// ```
///
/// צד שמאל הוא האמת: מחילים את ה-patch המקורי על המסד המלא, ואז גוזמים.
/// צד ימין הוא מה שהתוכנה עושה בפועל: גוזמים פעם אחת, ומאז מחילים patches
/// מסוננים. אם השניים מסכימים, המסנן נכון. אם לא — יש ספרייה שמתפצלת
/// בשקט מהמקור, וזה בדיוק הכשל שאין לו גלוי.
///
/// ההשוואה היא על ה-hash הלוגי, כלומר על **כל** תא בכל טבלה בסדר קנוני —
/// לא על ספירות שורות. שורה אחת עם תוכן שונה מפילה את הבדיקה.
void main() {
  late Directory dir;

  setUp(() => dir = createTempDir('equiv'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String at(String name) => p.join(dir.path, name);

  /// הכלל שנבדק: קטגוריה 10 בלבד. ספרים 1,2 בתוכה; 3,4 מחוץ לה.
  const spec = SubsetSpec(categoryIds: {10});

  String hashOf(String dbPath) {
    final db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      return const SubsetHasher().compute(db, schemaVersion: 5);
    } finally {
      db.close();
    }
  }

  Set<int> resolveOn(String dbPath) {
    final db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      return const SubsetResolver().resolveBookIds(db, spec);
    } finally {
      db.close();
    }
  }

  Set<int> categoriesOn(String dbPath, Set<int> bookIds) {
    final db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      return const SubsetResolver().resolveCategoryIds(
        db,
        selectedCategoryIds: spec.categoryIds,
        bookIds: bookIds,
      );
    } finally {
      db.close();
    }
  }

  DeltaManifest manifestFor(int from, int to) => DeltaManifest(
        fromVersion: from,
        toVersion: to,
        fromSchemaVersion: 5,
        toSchemaVersion: 5,
        patchFormatVersion: 4,
        // ה-hashes של אפסטרים אינם ברי-חישוב על fixture, והאימות מולם
        // כבוי בשני המסלולים כאחד — מה שנבדק כאן הוא השוויון בין שני
        // הצדדים, לא ההתאמה לאפסטרים.
        fromContentHash: 'x',
        toContentHash: 'y',
        patchFiles: const [],
      );

  /// מריץ את שני המסלולים על אותו patch ומחזיר את שני ה-hashes.
  ({
    String viaFull,
    String viaFilter,
    Set<int> keep,
    Set<int> pending,
  }) runBothPaths(
    void Function(sqlite3.Database db) mutate, {
    int from = 1,
    int to = 2,
    bool prune = true,
  }) {
    buildFullDb(at('full_v$from.db'), version: from);
    buildPatchDb(at('patch.db'),
        fromVersion: from, toVersion: to, mutate: mutate);

    // ── מסלול ב', שלב א': גיזום ראשוני מהמצב הישן ──
    final keepBefore = resolveOn(at('full_v$from.db'));
    const SubsetBuilder().build(
      sourcePath: at('full_v$from.db'),
      targetPath: at('b_subset.db'),
      bookIds: keepBefore,
      keepCategoryIds:
          prune ? categoriesOn(at('full_v$from.db'), keepBefore) : null,
    );

    // הבחירה האפקטיבית נפתרת מול ה-patch, לפני שני המסלולים, כדי ששניהם
    // יגזמו **אותה קבוצה**. השוואה בין קבוצות שונות חסרת משמעות.
    final sub = sqlite3.sqlite3.open(at('b_subset.db'));
    final PatchKeepResolution resolution;
    try {
      resolution =
          const SubsetResolver().resolveForPatch(sub, spec, at('patch.db'));
    } finally {
      sub.close();
    }

    // ── מסלול א': מחילים על המלא, ואז גוזמים ──
    File(at('full_v$from.db')).copySync(at('full_v$to.db'));
    const PatchApplier().apply(
      dbPath: at('full_v$to.db'),
      patchPath: at('patch.db'),
      manifest: manifestFor(from, to),
      verifyFromHash: false,
      verifyToHash: false,
    );
    const SubsetBuilder().build(
      sourcePath: at('full_v$to.db'),
      targetPath: at('a_subset.db'),
      bookIds: resolution.keep,
      // אותה קבוצת קטגוריות בדיוק כמו במסלול ב'. שני המסלולים חייבים
      // לגזום זהה, אחרת ההשוואה בודקת שני דברים שונים.
      keepCategoryIds: prune ? resolution.keepCategories : null,
    );

    // מה שהכלל בוחר במסד המלא חייב להתפרק בדיוק ל"ניתן לתחזוקה" +
    // "ממתין להבאה". ספר שנפל בין הכיסאות הוא ספר שנעלם בשקט.
    expect(
      {...resolution.keep, ...resolution.pendingAcquisition},
      resolveOn(at('full_v$to.db')),
      reason: 'resolveForPatch חלק על resolve מול המסד המלא',
    );

    // ── מסלול ב', שלב ב': patch מסונן על התת-קבוצה ──
    const PatchFilter().filter(
      patchPath: at('patch.db'),
      subsetPath: at('b_subset.db'),
      outputPath: at('patch_filtered.db'),
      bookIds: resolution.keep,
      keepCategoryIds: prune ? resolution.keepCategories : null,
    );
    const PatchApplier().apply(
      dbPath: at('b_subset.db'),
      patchPath: at('patch_filtered.db'),
      manifest: manifestFor(from, to),
      verifyFromHash: false,
      verifyToHash: false,
    );

    return (
      viaFull: hashOf(at('a_subset.db')),
      viaFilter: hashOf(at('b_subset.db')),
      keep: resolution.keep,
      pending: resolution.pendingAcquisition,
    );
  }

  test('עדכון תוכן בספר שנבחר', () {
    final r = runBothPaths((db) {
      db.execute("INSERT INTO upsert_line VALUES "
          "(100, 1, 0, 'שורה מעודכנת', 12)");
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.viaFilter, r.viaFull);
  });

  test('עדכון תוכן בספר שלא נבחר אינו מדליף לתת-הקבוצה', () {
    final r = runBothPaths((db) {
      db.execute("INSERT INTO upsert_line VALUES "
          "(300, 3, 0, 'שורה בספר שלא נבחר', 12)");
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.viaFilter, r.viaFull);
  });

  test('שורה חדשה בספר שנבחר', () {
    final r = runBothPaths((db) {
      db.execute("INSERT INTO upsert_line VALUES (103, 1, 3, 'שורה חדשה', 9)");
      db.execute('INSERT INTO upsert_line_toc VALUES (103, 1)');
      db.execute("INSERT INTO upsert_version_line VALUES (1, 103, 'נוסח חדש')");
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.viaFilter, r.viaFull);
  });

  test('ספר חדש בקטגוריה שנבחרה נכנס מעצמו', () {
    final r = runBothPaths((db) {
      db.execute("INSERT INTO upsert_book VALUES (5, 10, 'ספר חדש', 2)");
      db.execute('INSERT INTO upsert_book_author VALUES (5, 1)');
      db.execute('INSERT INTO upsert_tocEntry VALUES (5, 5, 1, 0)');
      db.execute("INSERT INTO upsert_book_version VALUES (5, 5, 'נוסח א')");
      for (var i = 0; i < 2; i++) {
        db.execute("INSERT INTO upsert_line VALUES "
            "(${500 + i}, 5, $i, 'חדש 5/$i', 8)");
        db.execute('INSERT INTO upsert_line_toc VALUES (${500 + i}, 5)');
        db.execute("INSERT INTO upsert_version_line VALUES "
            "(5, ${500 + i}, 'נוסח 5/$i')");
      }
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.keep, {1, 2, 5}, reason: 'הספר החדש חייב להיכנס לבחירה');
    expect(r.viaFilter, r.viaFull);
  });

  test('ספר חדש בקטגוריה שלא נבחרה נשאר בחוץ', () {
    final r = runBothPaths((db) {
      db.execute("INSERT INTO upsert_book VALUES (6, 11, 'ספר חדש בחוץ', 1)");
      db.execute("INSERT INTO upsert_line VALUES (600, 6, 0, 'בחוץ', 5)");
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.keep, {1, 2});
    expect(r.viaFilter, r.viaFull);
  });

  test('קישור פנימי חדש נשמר, קישור חוצה-גבול חדש מנותק', () {
    final r = runBothPaths((db) {
      // פנימי: 2→1, שני הצדדים בבחירה.
      db.execute('INSERT INTO upsert_link VALUES (4, 2, 1, 200, 100)');
      db.execute('INSERT INTO upsert_link_anchor VALUES (4, 0, 0, 3, NULL)');
      // חוצה גבול: 2→4.
      db.execute('INSERT INTO upsert_link VALUES (5, 2, 4, 201, 400)');
      db.execute('INSERT INTO upsert_link_anchor VALUES (5, 0, 0, 3, NULL)');
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.viaFilter, r.viaFull);
  });

  test('מחיקת שורה מספר שנבחר', () {
    final r = runBothPaths((db) {
      db.execute('INSERT INTO delete_version_line VALUES (2, 202)');
      db.execute('INSERT INTO delete_line_toc VALUES (202)');
      db.execute('INSERT INTO delete_line VALUES (202)');
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.viaFilter, r.viaFull);
  });

  test('מחיקת ספר שלם שנבחר', () {
    final r = runBothPaths((db) {
      for (var i = 0; i < 3; i++) {
        db.execute('INSERT INTO delete_version_line VALUES (2, ${200 + i})');
        db.execute('INSERT INTO delete_line_toc VALUES (${200 + i})');
        db.execute('INSERT INTO delete_line VALUES (${200 + i})');
      }
      db.execute('INSERT INTO delete_link VALUES (1)');
      db.execute('INSERT INTO delete_link VALUES (3)');
      db.execute('INSERT INTO delete_link_anchor VALUES (1, 0, 0)');
      db.execute('INSERT INTO delete_link_anchor VALUES (3, 0, 0)');
      db.execute('INSERT INTO delete_book_version VALUES (2)');
      db.execute('INSERT INTO delete_tocEntry VALUES (2)');
      db.execute('INSERT INTO delete_book_author VALUES (2, 2)');
      db.execute('INSERT INTO delete_book VALUES (2)');
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.keep, {1});
    expect(r.viaFilter, r.viaFull);
  });

  test('שינוי בטבלה גלובלית עובר במלואו', () {
    final r = runBothPaths((db) {
      db.execute("INSERT INTO upsert_author VALUES (3, 'מחבר חדש')");
      db.execute("INSERT INTO upsert_tocText VALUES (3, 'פרק ג')");
      db.execute(
          "INSERT INTO upsert_category VALUES (12, 1, 'קטגוריה חדשה', 1, 3)");
      db.execute('INSERT INTO upsert_category_closure VALUES (1, 12)');
      db.execute('INSERT INTO upsert_category_closure VALUES (12, 12)');
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.viaFilter, r.viaFull);
  });

  test('ספר עובר מקטגוריה שנבחרה לקטגוריה שלא נבחרה', () {
    final r = runBothPaths((db) {
      db.execute("INSERT INTO upsert_book VALUES (2, 11, 'ספר 2', 3)");
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.keep, {1}, reason: 'ספר 2 יצא מהבחירה');
    expect(r.viaFilter, r.viaFull);
  });

  test('ספר ותיק שנכנס לבחירה מסומן להבאה ולא נכנס חצי-ריק', () {
    // ספר 3 קיים באוצריא מזמן ורק עובר קטגוריה. ה-patch נושא את שורת
    // ה-`book` שלו בלבד — הטקסט לא השתנה ולכן אינו שם. אין דרך להשיג
    // אותו מכאן, וזו התכונה שהבדיקה נועלת: הוא יורד ל-pendingAcquisition
    // במקום להיכנס לספרייה בלי אף שורה.
    final r = runBothPaths((db) {
      db.execute("INSERT INTO upsert_book VALUES (3, 10, 'ספר 3', 3)");
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.pending, {3}, reason: 'ספר 3 ממתין להבאה ממסד מלא');
    expect(r.keep, {1, 2});
    expect(r.viaFilter, r.viaFull);
  });

  test('שילוב: הוספה, עדכון, מחיקה וקישורים באותו patch', () {
    final r = runBothPaths((db) {
      db.execute("INSERT INTO upsert_book VALUES (5, 10, 'ספר חדש', 1)");
      db.execute("INSERT INTO upsert_line VALUES (500, 5, 0, 'חדש', 4)");
      db.execute("INSERT INTO upsert_line VALUES (100, 1, 0, 'עודכן', 6)");
      db.execute("INSERT INTO upsert_line VALUES (300, 3, 0, 'בחוץ', 6)");
      db.execute('INSERT INTO upsert_link VALUES (4, 1, 5, 101, 500)');
      db.execute('INSERT INTO upsert_link VALUES (5, 5, 3, 500, 300)');
      db.execute('INSERT INTO delete_version_line VALUES (2, 202)');
      db.execute('INSERT INTO delete_line_toc VALUES (202)');
      db.execute('INSERT INTO delete_line VALUES (202)');
      db.execute("INSERT INTO upsert_author VALUES (3, 'מחבר ג')");
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.keep, {1, 2, 5});
    expect(r.viaFilter, r.viaFull);
  });

  test('שורה עוברת לספר שלא נבחר יחד עם הצאצאים שלה באותו patch', () {
    // ההורה קיים מקומית ולכן הצאצא עובר את הסינון, אבל המחיקה המסונתזת
    // של ההורה חייבת לסחוף אותו — אחרת נשאר צאצא יתום.
    final r = runBothPaths((db) {
      db.execute("INSERT INTO upsert_line VALUES (101, 3, 9, 'עבר', 4)");
      db.execute('INSERT INTO upsert_line_toc VALUES (101, 1)');
      db.execute("INSERT INTO upsert_version_line VALUES (1, 101, 'עבר')");
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.viaFilter, r.viaFull);
  });

  test('קישור פנימי שהופך לחוצה-גבול, עם עוגן מעודכן באותו patch', () {
    final r = runBothPaths((db) {
      db.execute('INSERT INTO upsert_link VALUES (1, 1, 3, 100, 300)');
      db.execute("INSERT INTO upsert_link_anchor VALUES (1, 0, 0, 9, 'x')");
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.viaFilter, r.viaFull);
  });

  test('שורה קיימת בטבלת הורה שה-patch מפנה להורה שלא שרד', () {
    // ‏line_toc.tocEntryId אינו חלק מה-PK: ה-upsert נופל בסינון, והשורה
    // המקומית חייבת להימחק ולא להישאר עם ההפניה הישנה.
    final r = runBothPaths((db) {
      db.execute('INSERT INTO upsert_line_toc VALUES (100, 3)');
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.viaFilter, r.viaFull);
  });

  test('שורה עוברת מספר שלא נבחר לספר שנבחר', () {
    final r = runBothPaths((db) {
      db.execute("INSERT INTO upsert_line VALUES (300, 1, 9, 'נכנס', 5)");
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.viaFilter, r.viaFull);
  });

  test('patch ריק אינו משנה דבר', () {
    final r = runBothPaths((db) {
      db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
    });
    expect(r.viaFilter, r.viaFull);
  });

  group('בלי גיזום עץ הקטגוריות', () {
    // העץ השלם הוא עדיין מצב נתמך, ולכן השקילות חייבת להחזיק גם בו.
    test('עדכון תוכן', () {
      final r = runBothPaths(prune: false, (db) {
        db.execute("INSERT INTO upsert_line VALUES (100, 1, 0, 'עודכן', 6)");
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
      });
      expect(r.viaFilter, r.viaFull);
    });

    test('שילוב מלא', () {
      final r = runBothPaths(prune: false, (db) {
        db.execute("INSERT INTO upsert_book VALUES (5, 10, 'ספר חדש', 1)");
        db.execute("INSERT INTO upsert_line VALUES (500, 5, 0, 'חדש', 4)");
        db.execute('INSERT INTO upsert_link VALUES (4, 1, 5, 101, 500)');
        db.execute('INSERT INTO delete_version_line VALUES (2, 202)');
        db.execute('INSERT INTO delete_line_toc VALUES (202)');
        db.execute('INSERT INTO delete_line VALUES (202)');
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
      });
      expect(r.viaFilter, r.viaFull);
    });
  });

  group('גיזום עץ הקטגוריות', () {
    /// כמה קטגוריות יש במסד שנבנה במסלול ב'.
    int categoryCount() {
      final db = sqlite3.sqlite3
          .open(at('b_subset.db'), mode: sqlite3.OpenMode.readOnly);
      try {
        return db.select('SELECT COUNT(*) c FROM category').first['c'] as int;
      } finally {
        db.close();
      }
    }

    test('קטגוריה שאין בה ספר נבחר נגזמת', () {
      // ה-fixture: שורש(1), נבחרת(10), לא-נבחרת(11). הבחירה היא {10},
      // ולכן 11 חייבת לרדת ו-1 להישאר כנתיב לשורש.
      final r = runBothPaths((db) {
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
      });
      expect(r.viaFilter, r.viaFull);
      expect(categoryCount(), 2, reason: 'נשארו שורש ו-10 בלבד');
    });

    test('בלי גיזום כל הקטגוריות נשמרות', () {
      runBothPaths(prune: false, (db) {
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
      });
      expect(categoryCount(), 3);
    });

    test('תת-קטגוריה חדשה תחת קטגוריה שנבחרה נכנסת, וספר בתוכה מגיע', () {
      // זה המקרה שבגללו הכלל כולל "צאצאי הקטגוריות שנבחרו": בלעדיו
      // קטגוריה 12 הייתה נגזמת, והספר שבתוכה לא היה נפתר לעולם.
      final r = runBothPaths((db) {
        db.execute("INSERT INTO upsert_category VALUES (12, 10, 'תת', 2, 1)");
        db.execute('INSERT INTO upsert_category_closure VALUES (1, 12)');
        db.execute('INSERT INTO upsert_category_closure VALUES (10, 12)');
        db.execute('INSERT INTO upsert_category_closure VALUES (12, 12)');
        db.execute("INSERT INTO upsert_book VALUES (5, 12, 'ספר בתת', 1)");
        db.execute("INSERT INTO upsert_line VALUES (500, 5, 0, 'חדש', 4)");
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
      });
      expect(r.keep, {1, 2, 5}, reason: 'הספר בתת-הקטגוריה נכנס');
      expect(r.viaFilter, r.viaFull);
      expect(categoryCount(), 3, reason: 'שורש, 10, ו-12 החדשה');
    });

    test('קטגוריה חדשה מחוץ לבחירה אינה נכנסת', () {
      final r = runBothPaths((db) {
        db.execute("INSERT INTO upsert_category VALUES (13, 11, 'תת', 2, 1)");
        db.execute('INSERT INTO upsert_category_closure VALUES (1, 13)');
        db.execute('INSERT INTO upsert_category_closure VALUES (11, 13)');
        db.execute('INSERT INTO upsert_category_closure VALUES (13, 13)');
        db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','2')");
      });
      expect(r.viaFilter, r.viaFull);
      expect(categoryCount(), 2);
    });
  });
}

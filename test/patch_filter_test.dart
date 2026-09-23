import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'fixtures.dart';

/// בדיקות ל-[PatchFilter] — צמצום קובץ `patch.db` לספרים שיש למשתמש.
///
/// הפלט חייב להישאר `patch.db` תקף לכל דבר, כי `PatchApplier` מחיל אותו
/// בלי לדעת שהוא סונן. שלוש ההחלטות שנבדקות: מחיקות עוברות במלואן,
/// שדרוגים מסוננים לפי ספר, וטבלה שנקבעת לפי הורה נבדקת מול המסד
/// המקומי **ומול מה שה-patch עצמו מוסיף**.
void main() {
  late Directory dir;

  setUp(() {
    dir = createTempDir('filter');
    // מסד מלא, ותת-קבוצה של ספרים 1,2 — נקודת הפתיחה של כל בדיקה כאן.
    buildFullDb(p.join(dir.path, 'full.db'));
    const SubsetBuilder().build(
      sourcePath: p.join(dir.path, 'full.db'),
      targetPath: p.join(dir.path, 'sub.db'),
      bookIds: {1, 2},
    );
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String at(String name) => p.join(dir.path, name);

  /// בונה patch עם [mutate] ומסנן אותו לבחירה [bookIds].
  PatchFilterReport run(
    void Function(sqlite3.Database db) mutate, {
    Set<int> bookIds = const {1, 2},
    String output = 'out.db',
  }) {
    buildPatchDb(at('patch.db'), fromVersion: 1, toVersion: 2, mutate: mutate);
    return const PatchFilter().filter(
      patchPath: at('patch.db'),
      subsetPath: at('sub.db'),
      outputPath: at(output),
      bookIds: bookIds,
    );
  }

  T onOut<T>(T Function(sqlite3.Database db) body, {String name = 'out.db'}) {
    final db = sqlite3.sqlite3.open(at(name), mode: sqlite3.OpenMode.readOnly);
    try {
      return body(db);
    } finally {
      db.close();
    }
  }

  Set<Object?> colOf(sqlite3.Database db, String table, String column) =>
      db.select('SELECT "$column" FROM "$table"').map((r) => r[column]).toSet();

  group('סירוב ותקינות הקלט', () {
    test('patch עם מיגרציות נדחה והפלט אינו נשאר מאחור', () {
      // מיגרציה היא SQL שנכתב בהנחה שהמסד שלם; backfill עליה היה נותן
      // על תת-קבוצה תוצאה אחרת בשקט. הכשל הרועש הוא ההגנה.
      expect(
        () => run((db) => db.execute(
            "INSERT INTO migrations VALUES (2, 'ALTER TABLE book ADD x')")),
        throwsA(isA<PatchFilterException>().having(
          (e) => e.message,
          'message',
          contains('מיגרצי'),
        )),
      );
      expect(File(at('out.db')).existsSync(), isFalse);
    });

    test('קובץ פלט קיים הוא שגיאה ולא דריסה', () {
      File(at('out.db')).writeAsStringSync('כבר כאן');
      expect(
        () => run((_) {}),
        throwsA(isA<PatchFilterException>()),
      );
      expect(File(at('out.db')).readAsStringSync(), 'כבר כאן');
    });

    test('קובץ patch חסר מדווח בהודעה ברורה', () {
      expect(
        () => const PatchFilter().filter(
          patchPath: at('nope.db'),
          subsetPath: at('sub.db'),
          outputPath: at('out.db'),
          bookIds: const {1},
        ),
        throwsA(isA<PatchFilterException>().having(
          (e) => e.message,
          'message',
          allOf(contains('patch'), contains('אינו קיים')),
        )),
      );
    });

    test('מסד חלקי חסר מדווח בהודעה ברורה', () {
      buildPatchDb(at('patch.db'), fromVersion: 1, toVersion: 2);
      expect(
        () => const PatchFilter().filter(
          patchPath: at('patch.db'),
          subsetPath: at('nope.db'),
          outputPath: at('out.db'),
          bookIds: const {1},
        ),
        throwsA(isA<PatchFilterException>().having(
          (e) => e.message,
          'message',
          allOf(contains('החלקי'), contains('אינו קיים')),
        )),
      );
    });
  });

  group('מטא-דאטה של הפלט', () {
    test('patch_meta מועתק על from/to וגרסת הפורמט', () {
      // ה-preflight של PatchApplier משווה את השלושה למניפסט; פלט בלעדיהם
      // אינו patch.
      run((db) => db.execute("INSERT INTO upsert_author VALUES (3, 'מחבר ג')"));
      onOut((db) {
        final meta = {
          for (final r in db.select('SELECT key, value FROM patch_meta'))
            r['key'] as String: r['value'] as String,
        };
        expect(meta['from_version'], '1');
        expect(meta['to_version'], '2');
        expect(meta['schema_version'], '4');
      });
    });
  });

  group('מחיקות', () {
    test('delete_* מועתקות במלואן גם לספר שאינו בבחירה', () {
      // ‏DELETE על שורה שאינה קיימת הוא no-op, ולכן סינון המחיקות היה
      // עבודה מיותרת עם סיכוי לטעות.
      final r = run((db) {
        db.execute('INSERT INTO delete_book VALUES (4)');
        db.execute('INSERT INTO delete_line VALUES (400)');
        db.execute('INSERT INTO delete_line VALUES (100)');
      });
      expect(r.kept['delete_book'], 1);
      expect(r.kept['delete_line'], 2);
      expect(r.dropped['delete_book'], isNull);
      onOut((db) {
        expect(colOf(db, 'delete_book', 'id'), {4});
        expect(colOf(db, 'delete_line', 'id'), {400, 100});
      });
    });
  });

  group('סינון לפי ספר', () {
    test('upsert_line נשמרת בתחום ונופלת מחוצה לו', () {
      final r = run((db) {
        db.execute("INSERT INTO upsert_line VALUES (100, 1, 0, 'א', 4)");
        db.execute("INSERT INTO upsert_line VALUES (300, 3, 0, 'ב', 4)");
        db.execute("INSERT INTO upsert_line VALUES (400, 4, 0, 'ג', 4)");
      });
      expect(r.kept['upsert_line'], 1);
      expect(r.dropped['upsert_line'], 2);
      onOut((db) => expect(colOf(db, 'upsert_line', 'id'), {100}));
    });

    test('upsert_link נשמר רק כששני הצדדים בבחירה', () {
      // מדיניות הניתוק סימטרית: גם קישור *נכנס* מספר שלא נבחר נופל.
      final r = run((db) {
        db.execute('INSERT INTO upsert_link VALUES (4, 1, 2, 100, 200)');
        db.execute('INSERT INTO upsert_link VALUES (5, 1, 3, 101, 300)');
        db.execute('INSERT INTO upsert_link VALUES (6, 4, 2, 400, 201)');
      });
      expect(r.kept['upsert_link'], 1);
      expect(r.dropped['upsert_link'], 2);
      onOut((db) => expect(colOf(db, 'upsert_link', 'id'), {4}));
    });

    test('טבלאות גלובליות עוברות במלואן בלי תלות בבחירה', () {
      // גיזום של author/tocText היה מפיל את אילוצי ה-UNIQUE הגלובליים.
      final r = run((db) {
        db.execute("INSERT INTO upsert_author VALUES (3, 'מחבר ג')");
        db.execute("INSERT INTO upsert_author VALUES (4, 'מחבר ד')");
        db.execute("INSERT INTO upsert_tocText VALUES (3, 'פרק ג')");
        db.execute("INSERT INTO upsert_category VALUES (12, 1, 'חדשה', 1, 3)");
      }, bookIds: const {1});
      expect(r.kept['upsert_author'], 2);
      expect(r.kept['upsert_tocText'], 1);
      expect(r.kept['upsert_category'], 1);
      expect(r.dropped['upsert_author'], isNull);
      expect(r.dropped['upsert_tocText'], isNull);
    });
  });

  group('סינון לפי הורה', () {
    test('upsert_link_anchor נשמר כשההורה כבר במסד החלקי', () {
      final r = run((db) {
        db.execute('INSERT INTO upsert_link_anchor VALUES (1, 0, 2, 7, NULL)');
      });
      expect(r.kept['upsert_link_anchor'], 1);
      onOut((db) => expect(colOf(db, 'upsert_link_anchor', 'linkId'), {1}));
    });

    test('upsert_link_anchor נשמר כשההורה מגיע באותו patch', () {
      // ההורה יכול להיות שורה שה-patch עצמו מוסיף; בדיקה מול המסד
      // המקומי בלבד הייתה מפילה כל עוגן של קישור חדש.
      final r = run((db) {
        db.execute('INSERT INTO upsert_link VALUES (4, 1, 2, 100, 200)');
        db.execute('INSERT INTO upsert_link_anchor VALUES (4, 0, 0, 3, NULL)');
      });
      expect(r.kept['upsert_link'], 1);
      expect(r.kept['upsert_link_anchor'], 1);
      onOut((db) => expect(colOf(db, 'upsert_link_anchor', 'linkId'), {4}));
    });

    test('upsert_link_anchor נופל כשההורה נותק או אינו קיים', () {
      final r = run((db) {
        // ‏5 הוא קישור חוצה-גבול שה-patch מוסיף ושנופל בסינון.
        db.execute('INSERT INTO upsert_link VALUES (5, 1, 3, 101, 300)');
        db.execute('INSERT INTO upsert_link_anchor VALUES (5, 0, 0, 3, NULL)');
        // ‏2 הוא קישור חוצה-גבול שכבר נותק בבניית התת-קבוצה.
        db.execute('INSERT INTO upsert_link_anchor VALUES (2, 0, 0, 3, NULL)');
      });
      expect(r.kept['upsert_link_anchor'], 0);
      expect(r.dropped['upsert_link_anchor'], 2);
      onOut((db) => expect(colOf(db, 'upsert_link_anchor', 'linkId'), isEmpty));
    });

    test('upsert_version_line נשמרת כששני ההורים מגיעים באותו patch', () {
      // האיחוד `sub ∪ main.upsert_<parent>`: ספר חדש לגמרי מביא את
      // ה-book_version, את ה-line ואת ה-version_line יחד.
      final r = run((db) {
        db.execute("INSERT INTO upsert_book VALUES (5, 10, 'ספר 5', 1)");
        db.execute("INSERT INTO upsert_book_version VALUES (5, 5, 'נוסח א')");
        db.execute("INSERT INTO upsert_line VALUES (500, 5, 0, 'שורה 5/0', 8)");
        db.execute("INSERT INTO upsert_version_line VALUES (5, 500, 'נ')");
        // הורה שאינו בבחירה — חייב ליפול.
        db.execute("INSERT INTO upsert_version_line VALUES (3, 300, 'נ')");
      }, bookIds: const {1, 2, 5});
      expect(r.kept['upsert_version_line'], 1);
      expect(r.dropped['upsert_version_line'], 1);
      onOut((db) => expect(colOf(db, 'upsert_version_line', 'versionId'), {5}));
    });
  });

  group('מחיקות מסונתזות', () {
    test('ספר שיוצא מהבחירה מקבל delete_book מסונתז', () {
      // בלי הסינתזה הזו הספר היה נשאר מקומית עם הערך הישן ומתחזה
      // לשורה מעודכנת, אף שהבחירה כבר אינה כוללת אותו.
      final r = run((db) {
        db.execute("INSERT INTO upsert_book VALUES (2, 11, 'ספר 2', 3)");
      }, bookIds: const {1});

      expect(r.totalSynthesizedDeletes, greaterThan(0));
      expect(r.synthesizedDeletes['delete_book'], 1);
      expect(r.dropped['upsert_book'], 1);
      onOut((db) => expect(colOf(db, 'delete_book', 'id'), {2}));
    });

    test('שורה שעוברת לספר שאינו בבחירה מקבלת delete_line מסונתז', () {
      final r = run((db) {
        // שורה 100 קיימת מקומית (ספר 1) וה-patch מעביר אותה לספר 3.
        db.execute("INSERT INTO upsert_line VALUES (100, 3, 0, 'א', 4)");
        // שורה 900 אינה קיימת מקומית — אין מה למחוק.
        db.execute("INSERT INTO upsert_line VALUES (900, 3, 1, 'ב', 4)");
      }, bookIds: const {1, 2});

      expect(r.synthesizedDeletes['delete_line'], 1);
      onOut((db) => expect(colOf(db, 'delete_line', 'id'), {100}));
    });

    test('patch בתחום אינו מסנתז מחיקות', () {
      final r = run((db) {
        db.execute("INSERT INTO upsert_line VALUES (100, 1, 0, 'א', 4)");
      });
      expect(r.totalSynthesizedDeletes, 0);
    });

    test('שורת line_toc קיימת שמופנית להורה שלא שרד מקבלת מחיקה מסונתזת', () {
      // ‏tocEntryId אינו ב-PK: ה-upsert נופל, ובלי מחיקה השורה המקומית
      // נשארת עם ההפניה הישנה.
      final r = run((db) {
        db.execute('INSERT INTO upsert_line_toc VALUES (100, 3)');
        // שורה 101 מקומית עם הורה ששרד — נשמרת ואינה נמחקת.
        db.execute('INSERT INTO upsert_line_toc VALUES (101, 2)');
        // שורה 300 אינה מקומית — אין מה למחוק.
        db.execute('INSERT INTO upsert_line_toc VALUES (300, 3)');
      });
      expect(r.synthesizedDeletes['delete_line_toc'], 1);
      onOut((db) {
        expect(colOf(db, 'delete_line_toc', 'lineId'), {100});
        expect(colOf(db, 'upsert_line_toc', 'lineId'), {101});
      });
    });
  });
}

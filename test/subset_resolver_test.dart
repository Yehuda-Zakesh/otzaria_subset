import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'fixtures.dart';

/// בדיקות פתירת הכלל.
///
/// ה-resolver הוא מה שקובע **מי בפנים**, ולכן טעות בו אינה מתגלה
/// כשגיאה אלא כספר חסר. שלושת החלקים שנבדקים כאן: פתירת הכלל עצמו,
/// דוח הקישורים שמוצג למשתמש לפני שהוא מאשר, והפתירה מול patch.
void main() {
  late Directory dir;

  setUp(() => dir = createTempDir('resolver'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String at(String name) => p.join(dir.path, name);
  const resolver = SubsetResolver();

  /// פותח את המסד המלא לקריאה ומריץ [body].
  T onFull<T>(T Function(sqlite3.Database db) body) {
    // בנייה פעם אחת לכל בדיקה: קריאה שנייה באותה בדיקה הייתה מנסה
    // ליצור מחדש סכמה שכבר קיימת.
    if (!File(at('full.db')).existsSync()) {
      buildFullDb(at('full.db'), version: 1);
    }
    final db =
        sqlite3.sqlite3.open(at('full.db'), mode: sqlite3.OpenMode.readOnly);
    try {
      return body(db);
    } finally {
      db.close();
    }
  }

  group('resolveBookIds', () {
    test('קטגוריה נבחרת מחזירה את ספריה', () {
      expect(
        onFull((db) =>
            resolver.resolveBookIds(db, const SubsetSpec(categoryIds: {10}))),
        {1, 2},
      );
    });

    test('קטגוריה אחרת', () {
      expect(
        onFull((db) =>
            resolver.resolveBookIds(db, const SubsetSpec(categoryIds: {11}))),
        {3, 4},
      );
    });

    test('שורש מחזיר הכל דרך הסגור', () {
      expect(
        onFull((db) =>
            resolver.resolveBookIds(db, const SubsetSpec(categoryIds: {1}))),
        {1, 2, 3, 4},
      );
    });

    test('שתי קטגוריות', () {
      expect(
        onFull((db) => resolver.resolveBookIds(
            db, const SubsetSpec(categoryIds: {10, 11}))),
        {1, 2, 3, 4},
      );
    });

    test('ספר מפורש נוסף לקטגוריות', () {
      expect(
        onFull((db) => resolver.resolveBookIds(
            db, const SubsetSpec(categoryIds: {10}, includeBookIds: {3}))),
        {1, 2, 3},
      );
    });

    test('החרגה גוברת על קטגוריה', () {
      expect(
        onFull((db) => resolver.resolveBookIds(
            db, const SubsetSpec(categoryIds: {10}, excludeBookIds: {2}))),
        {1},
      );
    });

    test('החרגה גוברת גם על הכללה מפורשת', () {
      // הסדר הזה הוא מה שמאפשר למשתמש להסיר ספר בודד מקטגוריה שנבחרה
      // בלי שההסרה תתבטל בעדכון הבא.
      expect(
        onFull((db) => resolver.resolveBookIds(
            db, const SubsetSpec(includeBookIds: {3}, excludeBookIds: {3}))),
        isEmpty,
      );
    });

    test('כלל ריק', () {
      expect(onFull((db) => resolver.resolveBookIds(db, SubsetSpec.empty)),
          isEmpty);
    });

    test('קטגוריה שאינה קיימת אינה זורקת', () {
      expect(
        onFull((db) =>
            resolver.resolveBookIds(db, const SubsetSpec(categoryIds: {999}))),
        isEmpty,
      );
    });

    test('ספר שאינו קיים בהכללה מוחזר כמות שהוא', () {
      // ה-resolver פותר **כלל**; אימות קיום הוא תפקיד הבנייה. שינוי
      // ההתנהגות הזו ישבור את הנחת ה-builder, ולכן היא נעולה כאן.
      expect(
        onFull((db) => resolver.resolveBookIds(
            db, const SubsetSpec(includeBookIds: {999}))),
        {999},
      );
    });
  });

  group('resolve — דוח הקישורים', () {
    SubsetPlan planFor(Set<int> categories, {int limit = 25}) => onFull(
          (db) => resolver.resolve(
            db,
            SubsetSpec(categoryIds: categories),
            severedLinkLimit: limit,
          ),
        );

    test('שני קישורים חוצי גבול נספרים', () {
      // ה-fixture: קישור 2 הוא 1→3 וקישור 3 הוא 4→2. שניהם חוצים.
      final plan = planFor({10});
      expect(plan.severedLinkCount, 2);
      expect(plan.hasSeveredLinks, isTrue);
      expect(plan.bookIds, {1, 2});
    });

    test('הספרים שבחוץ מדווחים עם כותרת וספירה', () {
      final plan = planFor({10});
      expect(plan.severedLinks.map((t) => t.bookId).toSet(), {3, 4});
      for (final target in plan.severedLinks) {
        expect(target.linkCount, 1);
        expect(target.title, isNotEmpty);
      }
    });

    test('הרשימה ממוינת לפי מספר קישורים יורד', () {
      final plan = planFor({10});
      final counts = plan.severedLinks.map((t) => t.linkCount).toList();
      final sorted = List<int>.of(counts)..sort((a, b) => b - a);
      expect(counts, orderedEquals(sorted));
    });

    test('אומדן גודל כולל את הרצפה הגלובלית', () {
      // ‏closureCostBytes אינו נבדק כאן כ-`> 0`: הכיול מחלק את גודל
      // הקובץ בסך השורות, ועל מסד fixture זעיר שקטן מהרצפה של ~20MB
      // התוצאה נחתכת ל-0. זו תכונה של האומדן על מסדי צעצוע, לא באג —
      // על המסד האמיתי (7.4GB) הכיול משמעותי.
      final plan = planFor({10});
      expect(plan.estimatedBytes, greaterThanOrEqualTo(20 * 1024 * 1024));
      expect(plan.closureCostBytes, greaterThanOrEqualTo(0));
    });

    test('בחירת הכל — אין ניתוק', () {
      final plan = planFor({1});
      expect(plan.severedLinkCount, 0);
      expect(plan.hasSeveredLinks, isFalse);
      expect(plan.severedLinks, isEmpty);
      expect(plan.closureCostBytes, 0);
    });

    test('בחירה ריקה — אין ניתוק, אבל הרצפה הגלובלית משולמת', () {
      // ~20MB של טבלאות גלובליות נשמרים בכל תת-קבוצה, גם ריקה. זו
      // תכונת תכנון ולא באג באומדן.
      final plan = planFor(const {});
      expect(plan.severedLinkCount, 0);
      expect(plan.estimatedBytes, greaterThan(0));
    });

    test('הגבלת הרשימה אינה משנה את הספירה', () {
      final plan = planFor({10}, limit: 1);
      expect(plan.severedLinks, hasLength(1));
      expect(plan.severedLinkCount, 2, reason: 'הספירה נשארת מלאה');
    });

    test('קישור ששני צדיו בחוץ אינו נספר', () {
      // בחירה {1} בלבד: קישור 3 הוא 4→2, שני הצדדים מחוץ לבחירה, ואין
      // שום משמעות ל"ניתוק" שלו — הוא לא היה שם מלכתחילה.
      final plan = onFull(
          (db) => resolver.resolve(db, const SubsetSpec(includeBookIds: {1})));
      expect(plan.bookIds, {1});
      expect(plan.severedLinks.map((t) => t.bookId).toSet(), {2, 3});
      expect(plan.severedLinkCount, 2);
    });

    test('שתי פתירות על אותו חיבור אינן מתערבבות', () {
      // ‏KeepSet מתאפס בכל install; בלי זה הבחירה השנייה הייתה מצטרפת
      // לראשונה וה-UI היה מציג מחיר של שתי בחירות יחד.
      buildFullDb(at('full.db'), version: 1);
      final db =
          sqlite3.sqlite3.open(at('full.db'), mode: sqlite3.OpenMode.readOnly);
      try {
        final first = resolver.resolve(db, const SubsetSpec(categoryIds: {10}));
        final second =
            resolver.resolve(db, const SubsetSpec(categoryIds: {11}));
        expect(first.bookIds, {1, 2});
        expect(second.bookIds, {3, 4});
        expect(second.severedLinkCount, 2);
      } finally {
        db.close();
      }
    });
  });

  group('resolveCategoryIds', () {
    Set<int> categoriesFor(Set<int> selected, Set<int> books) => onFull(
          (db) => resolver.resolveCategoryIds(
            db,
            selectedCategoryIds: selected,
            bookIds: books,
          ),
        );

    test('קטגוריה שנבחרה ואבותיה', () {
      expect(categoriesFor({10}, {1, 2}), {1, 10});
    });

    test('אבות של קטגוריית ספר שנבחר, בלי קטגוריה נבחרת', () {
      expect(categoriesFor(const {}, {3}), {1, 11});
    });

    test('שורש נבחר מחזיר את כל העץ', () {
      expect(categoriesFor({1}, {1, 2, 3, 4}), {1, 10, 11});
    });

    test('ריק לגמרי', () {
      expect(categoriesFor(const {}, const {}), isEmpty);
    });

    test('כל קלט לא ריק מחזיר את השורש', () {
      // בלי נתיב אל השורש עץ הספרייה באוצריא נשבר.
      expect(categoriesFor({10}, {1}), contains(1));
      expect(categoriesFor(const {}, {4}), contains(1));
    });
  });

  group('resolveForPatch', () {
    /// בונה תת-קבוצה של {1,2} ופותר מולה patch.
    PatchKeepResolution resolveWith(
      void Function(sqlite3.Database db) mutate, {
      SubsetSpec spec = const SubsetSpec(categoryIds: {10}),
    }) {
      buildFullDb(at('full.db'), version: 1);
      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('subset.db'),
        bookIds: {1, 2},
      );
      buildPatchDb(at('patch.db'),
          fromVersion: 1, toVersion: 2, mutate: mutate);

      // ‏uri: true נדרש — resolveForPatch מחבר את ה-patch עם mode=ro.
      final db = sqlite3.sqlite3.open(at('subset.db'), uri: true);
      try {
        return resolver.resolveForPatch(db, spec, at('patch.db'));
      } finally {
        db.close();
      }
    }

    test('ספר חדש עם שורות נכנס', () {
      final r = resolveWith((db) {
        db.execute("INSERT INTO upsert_book VALUES (5, 10, 'חדש', 1)");
        db.execute("INSERT INTO upsert_line VALUES (500, 5, 0, 'תוכן', 4)");
      });
      expect(r.keep, {1, 2, 5});
      expect(r.pendingAcquisition, isEmpty);
      expect(r.hasPending, isFalse);
    });

    test('ספר ותיק שרק עובר קטגוריה ממתין להבאה', () {
      final r = resolveWith((db) {
        db.execute("INSERT INTO upsert_book VALUES (3, 10, 'ספר 3', 3)");
      });
      expect(r.keep, {1, 2});
      expect(r.pendingAcquisition, {3});
      expect(r.hasPending, isTrue);
    });

    test('ספר שה-patch מוחק אינו באף קבוצה', () {
      final r = resolveWith((db) {
        db.execute('INSERT INTO delete_book VALUES (2)');
      });
      expect(r.keep, {1});
      expect(r.pendingAcquisition, isEmpty);
    });

    test('ספר חדש ריק לגיטימי נכנס', () {
      final r = resolveWith((db) {
        db.execute("INSERT INTO upsert_book VALUES (5, 10, 'ריק', 0)");
      });
      expect(r.keep, contains(5));
      expect(r.pendingAcquisition, isEmpty);
    });

    test('ספר חדש בקטגוריה שלא נבחרה אינו באף קבוצה', () {
      final r = resolveWith((db) {
        db.execute("INSERT INTO upsert_book VALUES (6, 11, 'בחוץ', 1)");
        db.execute("INSERT INTO upsert_line VALUES (600, 6, 0, 'תוכן', 4)");
      });
      expect(r.keep, {1, 2});
      expect(r.pendingAcquisition, isEmpty);
    });

    test('תת-קטגוריה חדשה — הספר נקלט והקטגוריה נשמרת', () {
      final r = resolveWith((db) {
        db.execute("INSERT INTO upsert_category VALUES (12, 10, 'תת', 2, 1)");
        db.execute('INSERT INTO upsert_category_closure VALUES (1, 12)');
        db.execute('INSERT INTO upsert_category_closure VALUES (10, 12)');
        db.execute('INSERT INTO upsert_category_closure VALUES (12, 12)');
        db.execute("INSERT INTO upsert_book VALUES (5, 12, 'בתת', 1)");
        db.execute("INSERT INTO upsert_line VALUES (500, 5, 0, 'תוכן', 4)");
      });
      expect(r.keep, {1, 2, 5});
      expect(r.keepCategories, contains(12));
    });

    test('הסרת תת-קטגוריה מוציאה את ספריה', () {
      final r = resolveWith(
        (db) {
          db.execute('INSERT INTO delete_category_closure VALUES (10, 10)');
        },
      );
      // בלי (10,10) בסגור, ספרי קטגוריה 10 אינם צאצאים של עצמה.
      expect(r.keep, isEmpty);
    });

    test('patch בלי תוכן — הבחירה נשארת כשהייתה', () {
      final r = resolveWith((db) {});
      expect(r.keep, {1, 2});
      expect(r.pendingAcquisition, isEmpty);
      expect(r.keepCategories, {1, 10});
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';

/// בדיקות להחזרת ספרים שנמחקו — `restoreSpecFor` ומה שמסביבו.
///
/// שני דברים כאן הם נכונות ולא נוחות: ההחזרה **רק מוסיפה** (שום דבר
/// שנשמר אינו נופל), וענף שהתמלא מתבטא ככלל קטגוריה ולא כרשימת ספרים
/// (§14 ב-AGENTS.md) — אחרת ספר עתידי בו לא היה מגיע לעולם.
void main() {
  CatalogCategory cat(int id, int? parentId, {int orderIndex = 1}) =>
      CatalogCategory(
        id: id,
        parentId: parentId,
        title: 'קטגוריה $id',
        level: 0,
        orderIndex: orderIndex,
      );

  CatalogBook book(int id, int categoryId, {int lines = 0}) => CatalogBook(
        id: id,
        categoryId: categoryId,
        title: 'ספר $id',
        totalLines: lines,
      );

  // התצלום המלא:
  //   1 → 10 (ספרים 1,2), 11 (ספרים 3,4) → 12 (ספר 5)
  //   2 → 20 (ספרים 6,7)
  final snapshot = LibraryCatalog(
    [
      cat(1, null),
      cat(10, 1),
      cat(11, 1),
      cat(12, 11),
      cat(2, null, orderIndex: 2),
      cat(20, 2),
    ],
    [
      book(1, 10),
      book(2, 10),
      book(3, 11),
      book(4, 11),
      book(5, 12),
      book(6, 20),
      book(7, 20),
    ],
    bytesPerLine: 100,
  );

  /// ההבטחה המרכזית: על עץ התצלום, מה שנשמר אחרי = מה שנשמר לפני ∪ מה
  /// שהוחזר. כל סטייה פירושה ספר שנעלם או ספר שנכנס בלי שביקשו.
  void expectKeepsExactly(
    SubsetSpec before,
    SubsetSpec after,
    Set<int> restored,
  ) {
    expect(
      keptBookIds(snapshot, after),
      {...keptBookIds(snapshot, before), ...restored},
    );
  }

  group('specKeepsBook / keptBookIds / notKeptBookIds', () {
    test('כלל קטגוריה מכסה כל עומק, והחרגה גוברת על הכל', () {
      const spec = SubsetSpec(
        categoryIds: {11},
        includeBookIds: {6, 5},
        excludeBookIds: {5},
      );
      expect(keptBookIds(snapshot, spec), {3, 4, 6});
      expect(notKeptBookIds(snapshot, spec), {1, 2, 5, 7});
    });

    test('תואם ל-keepSpecFor: מה שסומן למחיקה הוא בדיוק מה שאינו נשמר', () {
      final spec = keepSpecFor(
        snapshot,
        const RemovalSelection(categoryIds: {12}, bookIds: {2, 7}),
      );
      expect(notKeptBookIds(snapshot, spec), {2, 5, 7});
    });
  });

  group('restorableCatalog', () {
    test('מכיל רק את מה שאינו נשמר, ואת הקטגוריות שבדרך אליו', () {
      const spec = SubsetSpec(
        categoryIds: {10, 2},
        includeBookIds: {3},
      );
      final restorable = restorableCatalog(snapshot, spec);

      expect(restorable.books.map((b) => b.id).toSet(), {4, 5});
      expect(restorable.categories.map((c) => c.id).toSet(), {1, 11, 12});
      expect(restorable.roots.map((c) => c.id), [1]);
      expect(restorable.bytesPerLine, 100,
          reason: 'הגדלים שבעץ ההחזרה הם של התצלום המלא');
    });

    test('כשהכל נשמר, אין מה להחזיר', () {
      final restorable =
          restorableCatalog(snapshot, const SubsetSpec(categoryIds: {1, 2}));
      expect(restorable.books, isEmpty);
      expect(restorable.categories, isEmpty);
    });
  });

  group('restoreSpecFor', () {
    test('בחירה ריקה מחזירה את הכלל כמות שהוא', () {
      const current = SubsetSpec(categoryIds: {10}, excludeBookIds: {2});
      expect(
        restoreSpecFor(snapshot, current, RestoreSelection.empty),
        same(current),
      );
    });

    test('החזרת קטגוריה שנמחקה משלימה את השורש לכלל אחד', () {
      final current = keepSpecFor(
        snapshot,
        const RemovalSelection(categoryIds: {11}),
      );
      expect(current.categoryIds, {10, 2});

      final after = restoreSpecFor(
        snapshot,
        current,
        const RestoreSelection(categoryIds: {11}),
      );

      expect(after.categoryIds, {1, 2},
          reason: 'שורש 1 שלם שוב — קטגוריה אחת, ו-10 מיותרת תחתיו');
      expect(after.includeBookIds, isEmpty);
      expect(after.excludeBookIds, isEmpty);
      expectKeepsExactly(current, after, {3, 4, 5});
    });

    test('החזרת ספר בודד שהשלים ענף מעורב הופכת אותו לכלל קטגוריה', () {
      final current = keepSpecFor(
        snapshot,
        const RemovalSelection(bookIds: {2}),
      );
      expect(current.includeBookIds, {1});
      expect(current.excludeBookIds, {2});

      final after = restoreSpecFor(
        snapshot,
        current,
        const RestoreSelection(bookIds: {2}),
      );

      expect(after.categoryIds, {1, 2});
      expect(after.includeBookIds, isEmpty,
          reason: 'רשימת ספרים על ענף שלם הייתה חוסמת ספר עתידי בו');
      expect(after.excludeBookIds, isEmpty);
      expectKeepsExactly(current, after, {2});
    });

    test('החזרה חלקית: הענף נשאר מעורב והספר נכנס בנפרד', () {
      final current = keepSpecFor(
        snapshot,
        const RemovalSelection(categoryIds: {11}, bookIds: {2}),
      );

      final after = restoreSpecFor(
        snapshot,
        current,
        const RestoreSelection(bookIds: {3}),
      );

      expect(after.categoryIds, current.categoryIds);
      expect(after.includeBookIds, {1, 3});
      expect(after.excludeBookIds, {2},
          reason: 'מחיקה שלא הוחזרה נשארת במקומה');
      expectKeepsExactly(current, after, {3});
    });

    test('החזרת תת-קטגוריה בתוך ענף מעורב נשמרת ככלל על עצמה', () {
      final current = keepSpecFor(
        snapshot,
        const RemovalSelection(categoryIds: {12}, bookIds: {3}),
      );

      final after = restoreSpecFor(
        snapshot,
        current,
        const RestoreSelection(categoryIds: {12}),
      );

      expect(after.categoryIds, containsAll(<int>{12, 10, 2}));
      expect(after.categoryIds, isNot(contains(1)),
          reason: 'ספר 3 עדיין מחוץ — השורש אינו שלם');
      expect(after.includeBookIds, {4});
      expect(after.excludeBookIds, {3});
      expectKeepsExactly(current, after, {5});
    });

    test('ענף שההחזרה לא נגעה בו אינו משנה צורה', () {
      // שני ענפים מעורבים; מחזירים רק בראשון.
      final current = keepSpecFor(
        snapshot,
        const RemovalSelection(bookIds: {2, 7}),
      );
      expect(current.includeBookIds, {1, 6});

      final after = restoreSpecFor(
        snapshot,
        current,
        const RestoreSelection(bookIds: {2}),
      );

      expect(after.categoryIds, {1});
      expect(after.includeBookIds, {6},
          reason: 'ענף 2 לא נגעו בו — נשאר רשימה, והחרגת 7 נשארת');
      expect(after.excludeBookIds, {7});
      expectKeepsExactly(current, after, {2});
    });

    test('כלל קטגוריה עם החרגה: ההחזרה מסירה את ההחרגה בלבד', () {
      // כך נראה כלל שנבנה עם previous — הקטגוריה נשארה כלל, והספר שנמחק
      // מוחרג במפורש.
      const current = SubsetSpec(
        categoryIds: {10, 11, 2},
        excludeBookIds: {2},
      );

      final after = restoreSpecFor(
        snapshot,
        current,
        const RestoreSelection(bookIds: {2}),
      );

      expect(after.excludeBookIds, isEmpty);
      expect(after.includeBookIds, isEmpty,
          reason: 'הקטגוריה כבר מכסה את הספר — אין צורך ברשימה');
      expect(after.categoryIds, {1, 2});
      expectKeepsExactly(current, after, {2});
    });

    test('מה שאינו בתצלום עובר כמות שהוא', () {
      // קטגוריה 99 וספרים 500/501 חדשים מהתצלום: ממתין להבאה, או ספר
      // שנמחק אחרי שהתצלום נלקח.
      const current = SubsetSpec(
        categoryIds: {10, 99},
        includeBookIds: {500},
        excludeBookIds: {501},
      );

      final after = restoreSpecFor(
        snapshot,
        current,
        const RestoreSelection(bookIds: {6}),
      );

      expect(after.categoryIds, containsAll(<int>{10, 99}));
      expect(after.includeBookIds, containsAll(<int>{500, 6}));
      expect(after.excludeBookIds, {501});
    });

    test('מזהים להחזרה שאינם בתצלום נכנסים לכלל ישירות', () {
      const current = SubsetSpec(
        categoryIds: {10},
        excludeBookIds: {600},
      );

      final after = restoreSpecFor(
        snapshot,
        current,
        const RestoreSelection(categoryIds: {77}, bookIds: {600}),
      );

      expect(after.categoryIds, {10, 77});
      expect(after.includeBookIds, {600});
      expect(after.excludeBookIds, isEmpty);
    });

    test('החזרת הכל מתכנסת לשורשים בלבד', () {
      final current = keepSpecFor(
        snapshot,
        const RemovalSelection(categoryIds: {2, 12}, bookIds: {1}),
      );

      final after = restoreSpecFor(
        snapshot,
        current,
        RestoreSelection(bookIds: notKeptBookIds(snapshot, current)),
      );

      expect(after, const SubsetSpec(categoryIds: {1, 2}));
    });

    test('קטגוריה שהוחזרה ואין בה ספרים עדיין נכנסת ככלל', () {
      // ענף ריק בתצלום: המשתמש ביקש אותו כדי שמה שייכנס אליו יגיע.
      final withEmpty = LibraryCatalog(
        [cat(1, null), cat(10, 1), cat(13, 1)],
        [book(1, 10)],
      );
      const current = SubsetSpec(includeBookIds: {1});

      final after = restoreSpecFor(
        withEmpty,
        current,
        const RestoreSelection(categoryIds: {13}),
      );

      expect(after.categoryIds, {1}, reason: 'עם 13 השורש כולו נשמר — כלל אחד');
      expect(after.includeBookIds, isEmpty);
    });
  });

  // ייבוא בחירה (`_applyImported` ב-HomeShell): גזימה רק כשכל מה שהבחירה
  // שומרת כבר על הדיסק. טעות לכיוון "מצמצם" הייתה משאירה ספרים שביקשו
  // מחוץ לספרייה לתמיד — גזימה אינה מביאה דבר.
  group('importNarrowsOnly', () {
    bool narrows(
      SubsetSpec current,
      SubsetSpec imported, {
      bool hasSubset = true,
      LibraryCatalog? catalog,
      bool noSnapshot = false,
    }) =>
        importNarrowsOnly(
          hasSubset: hasSubset,
          snapshot: noSnapshot ? null : (catalog ?? snapshot),
          current: current,
          imported: imported,
        );

    test('ספרייה מלאה: כל ייבוא הוא גזימה, גם בלי תצלום', () {
      expect(
        narrows(
          SubsetSpec.empty,
          const SubsetSpec(categoryIds: {1, 2}),
          hasSubset: false,
          noSnapshot: true,
        ),
        isTrue,
      );
    });

    test('צמצום בלבד: גזימה', () {
      const current = SubsetSpec(categoryIds: {1});
      expect(narrows(current, const SubsetSpec(categoryIds: {10})), isTrue);
      expect(narrows(current, const SubsetSpec(includeBookIds: {3})), isTrue);
      expect(
        narrows(
          current,
          const SubsetSpec(categoryIds: {1}, excludeBookIds: {5}),
        ),
        isTrue,
      );
      // אותה בחירה בדיוק אינה מרחיבה.
      expect(narrows(current, current), isTrue);
    });

    test('הרחבה: בנייה ממסד מלא', () {
      const current = SubsetSpec(categoryIds: {10});
      expect(narrows(current, const SubsetSpec(categoryIds: {1})), isFalse);
      expect(
        narrows(
          current,
          const SubsetSpec(categoryIds: {10}, includeBookIds: {6}),
        ),
        isFalse,
      );
      // ספר שהוחרג כאן ומיובא כשמור — גם הוא אינו על הדיסק.
      expect(
        narrows(
          const SubsetSpec(categoryIds: {10}, excludeBookIds: {2}),
          const SubsetSpec(categoryIds: {10}),
        ),
        isFalse,
      );
    });

    test('ספרייה גזומה בלי תצלום: אי אפשר לדעת — בנייה ממסד מלא', () {
      expect(
        narrows(
          const SubsetSpec(categoryIds: {1}),
          const SubsetSpec(categoryIds: {10}),
          noSnapshot: true,
        ),
        isFalse,
      );
    });

    test('מזהה שאינו בתצלום (חדש ממנו): בנייה ממסד מלא', () {
      const current = SubsetSpec(categoryIds: {1, 2});
      expect(narrows(current, const SubsetSpec(categoryIds: {99})), isFalse);
      expect(
        narrows(current, const SubsetSpec(includeBookIds: {1, 999})),
        isFalse,
      );
    });

    test('ההשוואה מול התצלום ולא מול הקטלוג הגזום', () {
      // בקטלוג גזום שבו ענף 20 כבר אינו קיים, הבחירה {1,2} "מצמצמת" את
      // {1} — אבל מול התצלום היא מרחיבה.
      final pruned = LibraryCatalog(
        [cat(1, null), cat(10, 1), cat(11, 1), cat(12, 11), cat(2, null)],
        [book(1, 10), book(2, 10), book(3, 11), book(4, 11), book(5, 12)],
      );
      const current = SubsetSpec(categoryIds: {1});
      const imported = SubsetSpec(categoryIds: {1, 2});
      expect(narrows(current, imported, catalog: pruned), isTrue);
      expect(narrows(current, imported), isFalse);
    });
  });
}

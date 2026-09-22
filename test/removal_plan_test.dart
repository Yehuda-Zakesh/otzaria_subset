import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';

/// בדיקות ל-[keepSpecFor] — ההיפוך מ"מה המשתמש סימן למחיקה" ל"כלל
/// השמירה" שהמנוע משתמש בו. זו הנקודה הכי סבירה לטעות: המרה כיוונית
/// שגויה בשקט הייתה מייצרת בחירה שאינה מה שהמשתמש התכוון אליו.
///
/// הקטלוגים כאן נבנים ישירות מרשימות [CatalogCategory]/[CatalogBook],
/// בלי שום מסד — ‏`keepSpecFor` הוא לוגיקה טהורה על עץ שכבר בזיכרון.
void main() {
  CatalogCategory cat(int id, int? parentId, String title,
          {int orderIndex = 1}) =>
      CatalogCategory(
        id: id,
        parentId: parentId,
        title: title,
        level: 0,
        orderIndex: orderIndex,
      );

  CatalogBook book(int id, int categoryId, String title) => CatalogBook(
        id: id,
        categoryId: categoryId,
        title: title,
        totalLines: 0,
      );

  test('בחירה ריקה שומרת כל קטגוריית שורש ככלל שלם', () {
    // כלל, לא תצלום: ספר עתידי תחת אחד השורשים חייב להיכנס מעצמו.
    final catalog = LibraryCatalog(
      [
        cat(1, null, 'שורש א'),
        cat(2, 1, 'ילד'),
        cat(3, null, 'שורש ב'),
      ],
      [book(101, 2, 'ספר'), book(102, 3, 'ספר')],
    );

    final spec = keepSpecFor(catalog, RemovalSelection.empty);

    expect(spec.categoryIds, {1, 3});
    expect(spec.includeBookIds, isEmpty);
    expect(spec.excludeBookIds, isEmpty);
  });

  test('מחיקת קטגוריית שורש שלמה מוציאה אותה ואת כל צאצאיה מכלל השמירה', () {
    final catalog = LibraryCatalog(
      [
        cat(1, null, 'נמחקת'),
        cat(2, 1, 'תת-קטגוריה של הנמחקת'),
        cat(3, null, 'נשארת'),
      ],
      [book(101, 2, 'בענף שנמחק'), book(201, 3, 'בענף שנשאר')],
    );

    final spec = keepSpecFor(
      catalog,
      const RemovalSelection(categoryIds: {1}),
    );

    expect(spec.categoryIds, {3});
    expect(spec.includeBookIds, isEmpty);
    expect(spec.excludeBookIds, isEmpty,
        reason: 'הספר בענף שנמחק כבר לא נגיש דרך categoryIds, ולא נזקק '
            'לחריגה מפורשת');
  });

  test(
      'מחיקת תת-קטגוריה מקוננת: אחים לא-נגועים נשארים שלמים, '
      'והענף המעורב מתפרק לספרים בודדים', () {
    // R -> A (יש לו ספר ישיר + תת-ילד A1 עם ספר) , R -> B (שלם, לא נגוע).
    // מוחקים רק את A1 העמוק — A הופך מעורב ומתפרק, B נשאר כלל שלם.
    final catalog = LibraryCatalog(
      [
        cat(1, null, 'R'),
        cat(2, 1, 'A'),
        cat(4, 2, 'A1'),
        cat(3, 1, 'B'),
      ],
      [
        book(201, 2, 'ספר ישיר של A'),
        book(401, 4, 'ספר בתוך A1'),
        book(301, 3, 'ספר של B'),
        book(302, 3, 'ספר נוסף של B'),
      ],
    );

    final spec = keepSpecFor(
      catalog,
      const RemovalSelection(categoryIds: {4}),
    );

    expect(spec.categoryIds, {3}, reason: 'B לא נגוע ונשאר כלל שלם');
    expect(spec.includeBookIds, {201},
        reason: 'A מעורב: ספרו הישיר נשמר בנפרד, A1 כולו נעלם');
    expect(spec.excludeBookIds, isEmpty);
  });

  test(
      'מחיקת ספר בודד בענף אחר לא-נגוע: הענף מתפרק, האחים נשמרים בנפרד, '
      'הספר שהוסר לא מופיע ב-includeBookIds', () {
    final catalog = LibraryCatalog(
      [cat(1, null, 'R')],
      [book(101, 1, 'א'), book(102, 1, 'ב'), book(103, 1, 'ג')],
    );

    final spec = keepSpecFor(
      catalog,
      const RemovalSelection(bookIds: {102}),
    );

    expect(spec.categoryIds, isEmpty,
        reason: 'R מעורב — לא ניתן לשמור אותו ככלל שלם');
    expect(spec.includeBookIds, {101, 103});
    expect(spec.excludeBookIds, {102});
  });

  test(
      'מחיקת ספר בודד לצד קטגוריה נפרדת שנשארת שלמה: הספר שהוסר נופל '
      'ל-excludeBookIds, וספרי הקטגוריה השלמה לא מופיעים באף אחת מהרשימות', () {
    final catalog = LibraryCatalog(
      [
        cat(1, null, 'שלמה, לא נגועה'),
        cat(2, null, 'מעורבת'),
      ],
      [
        book(901, 1, 'ספר של השלמה'),
        book(902, 1, 'עוד ספר של השלמה'),
        book(903, 2, 'מוסר'),
        book(904, 2, 'נשאר'),
      ],
    );

    final spec = keepSpecFor(
      catalog,
      const RemovalSelection(bookIds: {903}),
    );

    expect(spec.categoryIds, {1});
    expect(spec.includeBookIds, {904});
    expect(spec.excludeBookIds, {903});
    // ספרי הקטגוריה השלמה מכוסים דרך categoryIds בלבד — הם לא אמורים
    // להישאב לאף אחת משתי הרשימות האחרות.
    expect(spec.includeBookIds, isNot(contains(901)));
    expect(spec.includeBookIds, isNot(contains(902)));
    expect(spec.excludeBookIds, isNot(contains(901)));
    expect(spec.excludeBookIds, isNot(contains(902)));
  });

  test(
      'קינון עמוק (4 רמות): מחיקת הצומת התחתון בלבד מפרקת רק את השרשרת '
      'מעליו, והאחים בכל רמה נשארים ככלל שלם', () {
    // L1 -> L2 -> L3 -> L4(נמחקת). לכל אחת מ-L1,L2 יש גם אח שלם ולא נגוע.
    final catalog = LibraryCatalog(
      [
        cat(1, null, 'L1'),
        cat(2, 1, 'L2'),
        cat(3, 2, 'L3'),
        cat(4, 3, 'L4 - נמחקת'),
        cat(5, 2, 'אח של L3'),
        cat(6, 1, 'אח של L2'),
      ],
      [
        book(401, 4, 'ספר עמוק שנעלם עם הקטגוריה'),
        book(501, 5, 'ספר של האח ברמה 3'),
        book(601, 6, 'ספר של האח ברמה 2'),
      ],
    );

    final spec = keepSpecFor(
      catalog,
      const RemovalSelection(categoryIds: {4}),
    );

    expect(spec.categoryIds, {5, 6},
        reason: 'האחים בכל רמה נותרו שלמים; L1,L2,L3 מעורבים ולא נכללים '
            'כקטגוריה');
    expect(spec.includeBookIds, isEmpty,
        reason: 'לאף אחת מהקטגוריות המעורבות (L1..L3) אין ספר ישיר');
    expect(spec.excludeBookIds, isEmpty);
  });
}

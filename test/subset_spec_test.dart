import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';

/// בדיקות המודלים של הבחירה והתוכנית.
///
/// ‏`SubsetSpec` נשמר לדיסק ונקרא מחדש בכל עדכון, ולכן הסבילות של
/// ‏`fromJson` לקובץ חלקי או מגרסה אחרת היא חלק מהחוזה: פרופיל שמתפוצץ
/// בקריאה פירושו מחשב שאיבד את הרשומה של מה הותקן עליו.
void main() {
  group('SubsetSpec — JSON', () {
    test('הלוך ושוב שומר את שלוש הקבוצות', () {
      const spec = SubsetSpec(
        categoryIds: {10, 3, 7},
        includeBookIds: {101, 5},
        excludeBookIds: {42},
      );
      final restored = SubsetSpec.fromJson(
        jsonDecode(jsonEncode(spec.toJson())) as Map<String, dynamic>,
      );
      expect(restored.categoryIds, equals({3, 7, 10}));
      expect(restored.includeBookIds, equals({5, 101}));
      expect(restored.excludeBookIds, equals({42}));
      expect(restored, equals(spec));
    });

    test('הקבוצות ממוינות ב-JSON', () {
      // ‏Set ב-Dart אינו מסודר; פלט לא ממוין היה מייצר diff בקובץ
      // הפרופיל בכל שמירה גם כשהבחירה לא השתנתה.
      const spec = SubsetSpec(
        categoryIds: {9, 1, 5},
        includeBookIds: {300, 2, 50},
        excludeBookIds: {8, 4},
      );
      final json = spec.toJson();
      expect(json['categoryIds'], equals([1, 5, 9]));
      expect(json['includeBookIds'], equals([2, 50, 300]));
      expect(json['excludeBookIds'], equals([4, 8]));
    });

    test('מיון אינו הופך את הקבוצה המקורית לרשימה משותפת', () {
      const spec = SubsetSpec(categoryIds: {2, 1});
      spec.toJson();
      expect(spec.categoryIds, equals({1, 2}));
    });

    test('fromJson סובלת שדות חסרים', () {
      final spec = SubsetSpec.fromJson(const {});
      expect(spec.categoryIds, isEmpty);
      expect(spec.includeBookIds, isEmpty);
      expect(spec.excludeBookIds, isEmpty);
    });

    test('fromJson סובלת null', () {
      final spec = SubsetSpec.fromJson(const {
        'categoryIds': null,
        'includeBookIds': null,
        'excludeBookIds': null,
      });
      expect(spec.isEmpty, isTrue);
    });

    test('fromJson סובלת ערך שאינו רשימה ואינה זורקת', () {
      // קובץ פרופיל מגרסה אחרת (או פגום למחצה) לא יכול להפיל את
      // הטעינה — הקבוצה הופכת ריקה והמשתמש בוחר מחדש.
      final spec = SubsetSpec.fromJson(const {
        'categoryIds': 'hello',
        'includeBookIds': 17,
        'excludeBookIds': <String, Object?>{},
      });
      expect(spec.categoryIds, isEmpty);
      expect(spec.includeBookIds, isEmpty);
      expect(spec.excludeBookIds, isEmpty);
    });

    test('fromJson ממירה double ל-int', () {
      // ‏jsonDecode מחזיר double כשהמספר נכתב עם נקודה עשרונית.
      final spec = SubsetSpec.fromJson(const {'categoryIds': [3.0, 4]});
      expect(spec.categoryIds, equals({3, 4}));
    });
  });

  group('SubsetSpec — סמנטיקה', () {
    test('empty ריקה', () {
      expect(SubsetSpec.empty.isEmpty, isTrue);
      expect(const SubsetSpec().isEmpty, isTrue);
    });

    test('קטגוריה או ספר בודד הופכים את הבחירה ללא-ריקה', () {
      expect(const SubsetSpec(categoryIds: {1}).isEmpty, isFalse);
      expect(const SubsetSpec(includeBookIds: {1}).isEmpty, isFalse);
    });

    test('exclude בלבד נחשב ריק', () {
      // ‏exclude הוא סינון על בחירה קיימת, לא בחירה בעצמו; בלעדיה
      // אין מה לגזום ואין ספרייה לבנות.
      expect(const SubsetSpec(excludeBookIds: {1, 2}).isEmpty, isTrue);
    });

    test('שוויון לפי תוכן ולא לפי זהות', () {
      expect(
        const SubsetSpec(categoryIds: {1, 2}, includeBookIds: {9}),
        equals(const SubsetSpec(categoryIds: {2, 1}, includeBookIds: {9})),
      );
    });

    test('הבדל בכל אחת משלוש הקבוצות שובר שוויון', () {
      const base = SubsetSpec(
        categoryIds: {1},
        includeBookIds: {2},
        excludeBookIds: {3},
      );
      expect(base, isNot(equals(const SubsetSpec(
        categoryIds: {99},
        includeBookIds: {2},
        excludeBookIds: {3},
      ))));
      expect(base, isNot(equals(const SubsetSpec(
        categoryIds: {1},
        includeBookIds: {99},
        excludeBookIds: {3},
      ))));
      expect(base, isNot(equals(const SubsetSpec(
        categoryIds: {1},
        includeBookIds: {2},
        excludeBookIds: {99},
      ))));
    });

    test('אובייקטים שווים חולקים hashCode', () {
      expect(
        const SubsetSpec(categoryIds: {1, 2}).hashCode,
        const SubsetSpec(categoryIds: {2, 1}).hashCode,
      );
    });
  });

  group('SubsetSpec.copyWith', () {
    const base = SubsetSpec(
      categoryIds: {1, 2},
      includeBookIds: {10},
      excludeBookIds: {20},
    );

    test('בלי ארגומנטים משאיר הכל', () {
      expect(base.copyWith(), equals(base));
    });

    test('מחליף רק את מה שהועבר', () {
      // ‏copyWith שמאפס שדה שלא נגעו בו היה מוחק ספרים שהמשתמש הסיר
      // ידנית בכל שינוי קטגוריה.
      final changed = base.copyWith(categoryIds: const {5});
      expect(changed.categoryIds, equals({5}));
      expect(changed.includeBookIds, equals({10}));
      expect(changed.excludeBookIds, equals({20}));
    });

    test('קבוצה ריקה מפורשת כן מנקה', () {
      final cleared = base.copyWith(excludeBookIds: const {});
      expect(cleared.excludeBookIds, isEmpty);
      expect(cleared.categoryIds, equals({1, 2}));
    });
  });

  group('SubsetPlan', () {
    SeveredLinkTarget target(int id, int bytes, {int links = 1}) =>
        SeveredLinkTarget(
          bookId: id,
          title: 'book-$id',
          linkCount: links,
          estimatedBytes: bytes,
        );

    test('closureCostBytes מסכם את כל היעדים המנותקים', () {
      // זה המחיר שהמשתמש רואה לפני שהוא מאשר ניתוק; חישוב חסר כאן
      // מציג לו מחיר קטן מהאמת.
      final plan = SubsetPlan(
        bookIds: const {1, 2},
        estimatedBytes: 1000,
        severedLinkCount: 5,
        severedLinks: [target(3, 700), target(4, 300), target(5, 25)],
      );
      expect(plan.closureCostBytes, 1025);
    });

    test('closureCostBytes אפס כשאין ניתוקים', () {
      const plan = SubsetPlan(
        bookIds: {1},
        estimatedBytes: 10,
        severedLinkCount: 0,
        severedLinks: [],
      );
      expect(plan.closureCostBytes, 0);
      expect(plan.hasSeveredLinks, isFalse);
    });

    test('hasSeveredLinks נגזר מהמונה ולא מאורך הרשימה', () {
      // הרשימה היא דוח לתצוגה ויכולה להיות מקוצרת; המונה הוא הספירה
      // האמיתית, ולכן הוא זה שקובע אם להציג אזהרה.
      const plan = SubsetPlan(
        bookIds: {1},
        estimatedBytes: 10,
        severedLinkCount: 3,
        severedLinks: [],
      );
      expect(plan.hasSeveredLinks, isTrue);
      expect(plan.closureCostBytes, 0);
    });
  });

  group('PatchKeepResolution', () {
    test('hasPending שקר כשאין ספרים ממתינים', () {
      const resolution = PatchKeepResolution(keep: {1, 2});
      expect(resolution.pendingAcquisition, isEmpty);
      expect(resolution.hasPending, isFalse);
    });

    test('hasPending אמת כשיש ספר שתוכנו אינו ב-patch', () {
      // ספר ממתין שנכנס בשקט לספרייה נראה קיים ונפתח ריק — hasPending
      // הוא מה שמונע מהמסלול הזה לעבור בלי דיווח.
      const resolution =
          PatchKeepResolution(keep: {1}, pendingAcquisition: {2, 3});
      expect(resolution.hasPending, isTrue);
      expect(resolution.pendingAcquisition, equals({2, 3}));
    });

    test('keep ריק עם ממתינים הוא מצב חוקי', () {
      const resolution =
          PatchKeepResolution(keep: {}, pendingAcquisition: {7});
      expect(resolution.keep, isEmpty);
      expect(resolution.hasPending, isTrue);
    });
  });
}

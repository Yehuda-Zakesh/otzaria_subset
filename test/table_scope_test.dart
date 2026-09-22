import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:seforim_library_updater/seforim_library_updater.dart';

/// **מבחן החוזה שבין הסיווג לסכמה.**
///
/// ‏`kTableScopesInFkOrder` הוא ההגדרה של "מה נשאר בספרייה חלקית". טבלה
/// שקיימת בסכמה ואינה מסווגת כאן פשוט לא תיעתק — הספרייה תיבנה, תיראה
/// תקינה, ותחסר מידע בשקט. לכן כל סחף בין שתי הרשימות חייב להפיל build.
void main() {
  final scopeNames = [for (final s in kTableScopesInFkOrder) s.name];
  final patchNames = [for (final t in kPatchTablesInFkOrder) t.name];

  group('כיסוי מול טבלאות ה-patch', () {
    test('כל טבלה במעדכן מסווגת כאן', () {
      // טבלה חדשה בסכמה שנוספה למעדכן ולא סווגה כאן תיעלם מתת-הקבוצה
      // בלי אף הודעה — זו הבדיקה שהופכת את ההשמטה לכשל build.
      final missing = patchNames.where((n) => !scopeNames.contains(n));
      expect(missing, isEmpty,
          reason: 'טבלאות ללא סיווג ב-kTableScopesInFkOrder: $missing');
    });

    test('אין כאן טבלה שהמעדכן אינו מכיר', () {
      // הכיוון ההפוך: סיווג לטבלה שנמחקה מהסכמה שולח את הבונה לטבלה
      // שאינה קיימת, ונפילה שם קורית רק בזמן ריצה על מסד אמיתי.
      final extra = scopeNames.where((n) => !patchNames.contains(n));
      expect(extra, isEmpty,
          reason: 'טבלאות מסווגות שאינן ב-kPatchTablesInFkOrder: $extra');
    });

    test('הסדר זהה לסדר ה-FK של המעדכן', () {
      // שתי הרשימות הן סדר מפתח זר. סחף בסדר פירושו העתקת צאצא לפני
      // הורה — כלומר כשל FK באמצע בנייה ארוכה.
      expect(scopeNames, equals(patchNames));
    });
  });

  group('שלמות הרשימה', () {
    test('בדיוק 37 טבלאות', () {
      expect(kTableScopesInFkOrder, hasLength(37));
    });

    test('אין שם טבלה כפול', () {
      // שם כפול שורד קומפילציה, ו-kTableScopeByName היה משתיק אחד
      // מהשניים — הסיווג שנשאר אינו בהכרח הנכון.
      expect(scopeNames.toSet(), hasLength(scopeNames.length));
    });

    test('kTableScopeByName מכסה את כל הרשימה', () {
      expect(kTableScopeByName.keys.toSet(), equals(scopeNames.toSet()));
      for (final scope in kTableScopesInFkOrder) {
        expect(kTableScopeByName[scope.name], same(scope));
      }
    });
  });

  group('עקביות הסיווג', () {
    test('byBook — עמודות ספר לא ריקות, בלי הורים', () {
      // ‏byBook בלי עמודות היה מסנן לפי שום תנאי, כלומר שומר הכל.
      for (final scope
          in kTableScopesInFkOrder.where((s) => s.kind == ScopeKind.byBook)) {
        expect(scope.bookColumns, isNotEmpty, reason: scope.name);
        expect(scope.parents, isEmpty, reason: scope.name);
        expect(scope.bookColumns.toSet(), hasLength(scope.bookColumns.length),
            reason: 'עמודת ספר כפולה ב-${scope.name}');
      }
    });

    test('byParent — הורים לא ריקים, בלי עמודות ספר', () {
      for (final scope
          in kTableScopesInFkOrder.where((s) => s.kind == ScopeKind.byParent)) {
        expect(scope.parents, isNotEmpty, reason: scope.name);
        expect(scope.bookColumns, isEmpty, reason: scope.name);
      }
    });

    test('global — שני השדות ריקים ו-isGlobal אמת', () {
      for (final scope
          in kTableScopesInFkOrder.where((s) => s.kind == ScopeKind.global)) {
        expect(scope.bookColumns, isEmpty, reason: scope.name);
        expect(scope.parents, isEmpty, reason: scope.name);
        expect(scope.isGlobal, isTrue, reason: scope.name);
      }
    });

    test('isGlobal אמת רק ל-ScopeKind.global', () {
      for (final scope in kTableScopesInFkOrder) {
        expect(scope.isGlobal, scope.kind == ScopeKind.global,
            reason: scope.name);
      }
    });
  });

  group('אינווריאנטת סדר ההורים', () {
    test('כל הורה מופיע לפני הטבלה שמפנה אליו', () {
      // הבונה מסתמך על כך שההורה כבר הועתק כשהוא מגיע לצאצא. הורה
      // שיושב אחרי הצאצא מייצר שורות שנזרקות (או כשל FK) בלי סיבה גלויה.
      for (var i = 0; i < kTableScopesInFkOrder.length; i++) {
        final scope = kTableScopesInFkOrder[i];
        for (final parent in scope.parents) {
          final parentIndex = scopeNames.indexOf(parent.table);
          expect(parentIndex, greaterThanOrEqualTo(0),
              reason: 'הורה לא מסווג: ${scope.name} → ${parent.table}');
          expect(parentIndex, lessThan(i),
              reason: '${scope.name} מפנה ל-${parent.table} '
                  'שיושב אחריו בסדר ה-FK');
        }
      }
    });

    test('אין טבלה שהיא ההורה של עצמה', () {
      // הפניה עצמית ב-byParent הופכת את תנאי השרידות למחזורי — הטבלה
      // נשמרת אם היא נשמרת, כלומר אין החלטה בכלל.
      for (final scope in kTableScopesInFkOrder) {
        for (final parent in scope.parents) {
          expect(parent.table, isNot(scope.name), reason: scope.name);
        }
      }
    });

    test('שדות ParentRef אינם ריקים ואין הורה כפול', () {
      for (final scope in kTableScopesInFkOrder) {
        for (final parent in scope.parents) {
          expect(parent.column, isNotEmpty, reason: scope.name);
          expect(parent.parentColumn, isNotEmpty, reason: scope.name);
        }
        final columns = [for (final p in scope.parents) p.column];
        expect(columns.toSet(), hasLength(columns.length),
            reason: 'עמודת הורה כפולה ב-${scope.name}');
      }
    });
  });

  group('kGlobalTables', () {
    test('בדיוק 11 הטבלאות הגלובליות הצפויות', () {
      // הרשימה הזו היא ~20MB שנשמרים במלואם כדי שאילוצי ה-UNIQUE
      // הגלובליים יתנהגו כמו באפסטרים. גריעה ממנה מחזירה את התנגשות
      // ה-UNIQUE שתועדה ב-tocText.
      expect(
        kGlobalTables,
        equals([
          'source',
          'author',
          'topic',
          'pub_place',
          'pub_date',
          'connection_type',
          'tocText',
          'generation',
          'category',
          'category_closure',
          'schema_meta',
        ]),
      );
    });

    test('kGlobalTables נגזרת מהסיווג ובסדר ה-FK', () {
      final derived = [
        for (final s in kTableScopesInFkOrder)
          if (s.kind == ScopeKind.global) s.name,
      ];
      expect(kGlobalTables, equals(derived));
    });

    test('schema_meta גלובלית', () {
      // ה-preflight של PatchApplier קורא ממנה db_version; גיזום שלה
      // הופך כל patch עתידי לבלתי-ניתן להחלה.
      expect(scopeFor('schema_meta')!.isGlobal, isTrue);
    });
  });

  group('scopeFor', () {
    test('מחזירה את הסיווג לטבלה מוכרת', () {
      final link = scopeFor('link');
      expect(link, isNotNull);
      expect(link!.kind, ScopeKind.byBook);
      expect(link.bookColumns, equals(['sourceBookId', 'targetBookId']));
    });

    test('מחזירה null לטבלה שאינה מסווגת', () {
      // ‏null הוא סימן העצירה: סכמה שהמנוע אינו מכיר. החזרת ברירת מחדל
      // כלשהי במקומו הייתה מעתיקה טבלה לא מובנת.
      expect(scopeFor('no_such_table'), isNull);
      expect(scopeFor(''), isNull);
      expect(scopeFor('LINK'), isNull);
    });
  });
}

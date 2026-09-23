import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:otzaria_subset_app/widgets/update_guard.dart';

import 'widget_harness.dart';

const _notFound = OtzariaUpdateSettings(source: 'x', found: false);
const _enabled = OtzariaUpdateSettings(source: 'x', found: true);
const _offline =
    OtzariaUpdateSettings(source: 'x', found: true, offlineMode: true);
// רק הסינכרון האוטומטי כבוי — הכפתור הידני באוצריא עדיין מחזיר הכול.
const _autoSyncOff =
    OtzariaUpdateSettings(source: 'x', found: true, autoSync: false);

void main() {
  Future<void> pumpBanner(
    WidgetTester tester,
    OtzariaUpdateSettings? settings, {
    VoidCallback? onRecheck,
  }) =>
      pumpInApp(
        tester,
        UpdateGuardBanner(settings: settings, onRecheck: onRecheck ?? () {}),
      );

  testWidgets('בלי הגדרות עדיין — לא מוצג כלום', (tester) async {
    await pumpBanner(tester, null);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('עדכון דלוק → אזהרה עם ההנחיה המלאה', (tester) async {
    await pumpBanner(tester, _enabled);
    expect(find.text('הספרים שתמחק יחזרו — צריך לכבות משהו באוצריא'),
        findsOneWidget);
    expect(find.textContaining(kHowToDisable), findsOneWidget);
    expectNoInternalTerms(tester);
  });

  testWidgets('ההגדרות לא נקראו → לא מוצג כמוגן', (tester) async {
    await pumpBanner(tester, _notFound);
    expect(find.text('לא הצלחנו לבדוק את ההגדרות של אוצריא'), findsOneWidget);
    expect(find.text('הכול מוגן'), findsNothing);
    expectNoInternalTerms(tester);
  });

  testWidgets('מצב מנותק → מוגן לגמרי', (tester) async {
    await pumpBanner(tester, _offline);
    expect(find.text('הכול מוגן'), findsOneWidget);
    expectNoInternalTerms(tester);
  });

  testWidgets('רק סינכרון אוטומטי כבוי → מוגן, עם אזהרה על הכפתור הידני',
      (tester) async {
    await pumpBanner(tester, _autoSyncOff);
    expect(find.text('מוגן, אבל לא ללחוץ על "עדכון ספרייה" באוצריא'),
        findsOneWidget);
    expect(find.text('הכול מוגן'), findsNothing);
    expectNoInternalTerms(tester);
  });

  testWidgets('"בדוק שוב" מפעיל את הבדיקה', (tester) async {
    var rechecks = 0;
    await pumpBanner(tester, _enabled, onRecheck: () => rechecks++);
    await tester.tap(find.text('בדוק שוב'));
    expect(rechecks, 1);
  });

  group('showUpdateGuardDialog', () {
    Future<bool?> choose(WidgetTester tester, String button) async {
      bool? result;
      await pumpInApp(
        tester,
        DialogLauncher<bool>(
          open: (context) => showUpdateGuardDialog(context, _enabled),
          onResult: (value) => result = value,
        ),
      );
      await tester.tap(find.text('פתח'));
      await tester.pumpAndSettle();
      expect(find.text(kHowToDisable), findsOneWidget);
      expectNoInternalTerms(tester);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('"חזרה" → false', (tester) async {
      expect(await choose(tester, 'חזרה'), isFalse);
    });

    testWidgets('המשך מודע → true', (tester) async {
      expect(await choose(tester, 'הבנתי, להמשיך בכל זאת'), isTrue);
    });
  });
}

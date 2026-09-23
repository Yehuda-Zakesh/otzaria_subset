import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset_app/widgets/disclaimer.dart';

import 'widget_harness.dart';

void main() {
  testWidgets('הדיאלוג מציג את ההבהרה ומחזיר true באישור', (tester) async {
    bool? result;
    await pumpInApp(
      tester,
      DialogLauncher<bool>(
        open: showDisclaimerDialog,
        onResult: (value) => result = value,
      ),
    );
    await tester.tap(find.text('פתח'));
    await tester.pumpAndSettle();

    expect(find.text(kDisclaimer), findsOneWidget);
    expectNoInternalTerms(tester);
    // בלי יציאה ברקע: ההבהרה נקראת לפני שמתחילים, לא מדלגים עליה.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text(kDisclaimer), findsOneWidget);

    await tester.tap(find.text('הבנתי, להמשיך'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.text(kDisclaimer), findsNothing);
  });

  testWidgets('השורה הקבועה מציגה את אותו נוסח, גם במצב כהה', (tester) async {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      await pumpInApp(tester, const DisclaimerFooter(), mode: mode);
      expect(find.text(kDisclaimer), findsOneWidget);
    }
  });
}

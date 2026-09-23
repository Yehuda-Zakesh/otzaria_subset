import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset_app/services/app_updater.dart';
import 'package:otzaria_subset_app/services/error_report.dart';
import 'package:otzaria_subset_app/widgets/app_update.dart';

import 'widget_harness.dart';

/// מחליף את ההורדה בזרם שהבדיקה שולטת בו — ההורדה האמיתית סוגרת את
/// התהליך בהצלחה.
class _FakeUpdater extends AppUpdater {
  final StreamController<double> controller;

  _FakeUpdater(this.controller);

  @override
  Stream<double> install(AppRelease release) => controller.stream;
}

final _release = AppRelease(
  version: '1.2.4',
  downloadUrl: Uri.parse('https://example.invalid/OtzariaSubset.exe'),
  sizeBytes: 9328956,
  sha256: 'a' * 64,
);

void main() {
  group('AppUpdateCard', () {
    testWidgets('מציג גרסה וגודל, והכפתור מפעיל התקנה', (tester) async {
      var installs = 0;
      await pumpInApp(
        tester,
        AppUpdateCard(release: _release, onInstall: () => installs++),
      );
      expect(find.text('יש גרסה חדשה של התוכנה'), findsOneWidget);
      expect(find.textContaining('גרסה 1.2.4 • 8.9 MB'), findsOneWidget);
      expectNoInternalTerms(tester);

      await tester.tap(find.text('עדכון התוכנה'));
      expect(installs, 1);
    });

    testWidgets('בלי גודל — לא מציגים "0 B"', (tester) async {
      await pumpInApp(
        tester,
        AppUpdateCard(
          release: AppRelease(
            version: '1.2.4',
            downloadUrl: _release.downloadUrl,
            sizeBytes: 0,
          ),
          onInstall: () {},
        ),
      );
      expect(
          find.text('גרסה 1.2.4. ההורדה נוגעת בתוכנה בלבד.'), findsOneWidget);
      expect(find.textContaining(' B'), findsNothing);
    });
  });

  group('showAppUpdateDialog', () {
    Future<bool? Function()> open(
      WidgetTester tester,
      StreamController<double> controller,
    ) async {
      bool? result;
      await pumpInApp(
        tester,
        DialogLauncher<bool>(
          open: (context) => showAppUpdateDialog(
            context,
            _release,
            updater: _FakeUpdater(controller),
          ),
          onResult: (value) => result = value,
        ),
      );
      await tester.tap(find.text('פתח'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('מוריד את הגרסה החדשה'), findsOneWidget);
      return () => result;
    }

    testWidgets('התקדמות מוצגת בפס', (tester) async {
      final controller = StreamController<double>();
      await open(tester, controller);
      controller.add(0.4);
      await tester.pump();
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0.4);
      await controller.close();
      await tester.pumpAndSettle();
    });

    testWidgets('ביטול אינו תקלה → false', (tester) async {
      final controller = StreamController<double>();
      final result = await open(tester, controller);
      await tester.tap(find.text('ביטול'));
      await tester.pumpAndSettle();
      expect(result(), isFalse);
      expect(find.text('מוריד את הגרסה החדשה'), findsNothing);
      expect(controller.hasListener, isFalse);
    });

    testWidgets('שגיאה ואז סיום → true, נרשם ביומן, וסגירה אחת בלבד',
        (tester) async {
      final controller = StreamController<double>();
      final result = await open(tester, controller);
      controller.addError(StateError('hash-mismatch-marker'));
      unawaited(controller.close());
      await tester.pumpAndSettle();

      expect(result(), isTrue);
      // pop שני היה סוגר גם את המסך שמתחת.
      expect(find.text('פתח'), findsOneWidget);
      expect(
        ErrorLog.instance.entries
            .any((e) => e.contains('hash-mismatch-marker')),
        isTrue,
      );
    });

    testWidgets('זרם שמסתיים בלי שגיאה הוא כשל → true', (tester) async {
      final controller = StreamController<double>();
      final result = await open(tester, controller);
      await controller.close();
      await tester.pumpAndSettle();
      expect(result(), isTrue);
    });
  });
}

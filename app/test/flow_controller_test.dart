import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset_app/services/app_updater.dart';
import 'package:otzaria_subset_app/services/update_flow.dart';
import 'package:otzaria_subset_app/state/app_settings.dart';
import 'package:otzaria_subset_app/state/app_state.dart';
import 'package:otzaria_subset_app/state/flow_controller.dart';

/// בודק העדכון העצמי בלי רשת — הבדיקות כאן על המנעולים, לא על עדכון.
class _NoUpdate extends AppUpdater {
  const _NoUpdate();
  @override
  Future<AppRelease?> check() async => null;
}

void main() {
  late Directory dir;
  late FlowController flow;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('flow_controller_test');
    flow = FlowController(
      AppState(AppSettingsStore.at(dir.path)),
      appUpdater: const _NoUpdate(),
    );
  });

  tearDown(() {
    flow.dispose();
    dir.deleteSync(recursive: true);
  });

  test('guardLaunch חוסם הפעלה שנייה בזמן הדיאלוגים', () async {
    final gate = Completer<bool>();
    final first = flow.guardLaunch(() => gate.future);
    expect(flow.busy, isTrue);
    var secondRan = false;
    final second = await flow.guardLaunch(() async => secondRan = true);
    expect(second, isFalse);
    expect(secondRan, isFalse);
    gate.complete(true);
    expect(await first, isTrue);
    expect(flow.busy, isFalse);
  });

  test('זרם פעיל חוסם פעולה נוספת עד שהוא נסגר', () async {
    final source = StreamController<FlowProgress>();
    flow.start('בדיקה', source.stream);
    expect(flow.busy, isTrue);
    expect(await flow.guardLaunch(() async => true), isFalse);
    source.add(const FlowProgress(FlowStage.done, 'הסתיים.'));
    await source.close();
    await pumpEventQueue();
    expect(flow.busy, isFalse);
    expect(flow.progress?.stage, FlowStage.done);
  });

  test('אחרי נקודת האל-חזור ביטול אינו אפשרי', () async {
    final source = StreamController<FlowProgress>();
    flow.start('בדיקה', source.stream);
    source.add(const FlowProgress(
      FlowStage.rebuilding,
      'מחליף',
      committing: true,
    ));
    await pumpEventQueue();
    expect(flow.committing, isTrue);
    await flow.cancel();
    expect(flow.cancelled, isFalse);
    expect(flow.busy, isTrue);
    await source.close();
  });

  test('ביטול לפני נקודת האל-חזור משחרר את המנעול', () async {
    final source = StreamController<FlowProgress>();
    flow.start('בדיקה', source.stream);
    await flow.cancel();
    expect(flow.cancelled, isTrue);
    expect(flow.busy, isFalse);
    expect(flow.error, isNotNull);
  });

  test('שגיאה מגיעה למסך בלי מונחים פנימיים, ופעולת ההמשך אינה רצה', () async {
    final source = StreamController<FlowProgress>();
    var followed = false;
    flow.start(
      'בדיקה',
      source.stream,
      onSuccess: () async => followed = true,
    );
    source.addError(StateError('patch hash mismatch in table line'));
    await source.close();
    await pumpEventQueue();
    expect(flow.error, isNotNull);
    expect(flow.error, isNot(contains('patch')));
    expect(followed, isFalse);
  });

  test('פעולת ההמשך רצה רק אחרי הצלחה', () async {
    final source = StreamController<FlowProgress>();
    var followed = false;
    flow.start(
      'בדיקה',
      source.stream,
      onSuccess: () async => followed = true,
    );
    await source.close();
    await pumpEventQueue();
    expect(followed, isTrue);
  });
}

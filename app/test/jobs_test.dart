import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset_app/jobs/jobs.dart';

/// יוצא בלי לשלוח הודעת סיום.
void _silentEntry(JobRequest<int> req) {}

/// זורק מחוץ לכל try.
void _throwingEntry(JobRequest<int> req) {
  throw StateError('boom');
}

void _doneEntry(JobRequest<int> req) {
  req.port.send(JobDone(req.args * 2));
}

void main() {
  test('isolate שיוצא בלי תוצאה מסתיים ב-JobFailed ולא נתקע', () async {
    final events = await runJob(_silentEntry, 1)
        .toList()
        .timeout(const Duration(seconds: 10));
    expect(events.last, isA<JobFailed>());
  });

  test('שגיאה שלא נתפסה מגיעה כ-JobFailed', () async {
    final events = await runJob(_throwingEntry, 1)
        .toList()
        .timeout(const Duration(seconds: 10));
    expect(events.whereType<JobFailed>(), hasLength(1));
    expect((events.last as JobFailed).message, contains('boom'));
  });

  test('JobDone עובר כרגיל', () async {
    final events = await runJob(_doneEntry, 21)
        .toList()
        .timeout(const Duration(seconds: 10));
    expect(events, hasLength(1));
    expect((events.single as JobDone).result, 42);
  });
}

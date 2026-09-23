import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:seforim_library_updater/seforim_library_updater.dart';

import '../jobs/jobs.dart';
import '../services/app_updater.dart';
import '../services/error_report.dart';
import '../services/update_flow.dart';
import '../widgets/format.dart';
import 'app_state.dart';

/// המצב של הפעולות הארוכות על הספרייה, מופרד מהמסכים.
///
/// ## למה זה לא יושב ב-`HomeShell`
///
/// כל פעולה חדשה (החזרת ספרים, הבאת ספרים ממתינים) צריכה את אותם
/// מנעולים: אין שתי פעולות על אותו קובץ, אין ביטול אחרי נקודת האל-חזור,
/// והספרייה נקראת מחדש בסוף. ריכוז שלהם כאן הוא מה שמונע מכל מסך לממש
/// אותם מחדש — ולשכוח אחד מהם. הדיאלוגים נשארים במסכים, כי הם צריכים
/// `BuildContext`.
class FlowController extends ChangeNotifier {
  final AppState state;
  final AppUpdater appUpdater;

  FlowController(this.state, {this.appUpdater = const AppUpdater()});

  var _disposed = false;

  // ── פעולה על הספרייה ────────────────────────────────────────────

  StreamSubscription<FlowProgress>? _flow;

  /// מהלחיצה הראשונה (עוד לפני הדיאלוגים) ועד שהזרם נסגר באמת. בלי זה
  /// לחיצה כפולה, או בדיקת עדכונים ברקע בזמן גזימה, היו מריצות שתי
  /// פעולות על אותו קובץ.
  var _launching = false;
  var _active = false;
  var _cancelled = false;

  /// נדבק עד סוף הזרימה: אחרי נקודת האל-חזור אין ביטול — ראו
  /// `FlowProgress.committing`.
  var _committing = false;

  String? _title;
  FlowProgress? _progress;
  String? _error;

  bool get busy => _launching || _active;
  bool get active => _active;
  bool get committing => _committing;
  bool get cancelled => _cancelled;
  String get title => _title ?? '';
  FlowProgress? get progress => _progress;
  String? get error => _error;

  /// שומר את [body] מפני הפעלה כפולה בזמן הדיאלוגים שלפני פעולה.
  /// מחזיר `false` אם כבר רצה פעולה, ואז [body] אינו נקרא בכלל.
  Future<bool> guardLaunch(Future<bool> Function() body) async {
    if (busy) return false;
    _launching = true;
    try {
      return await body();
    } finally {
      _launching = false;
    }
  }

  SubsetUpdateFlow? buildFlow() {
    final db = state.paths.libraryDbPath;
    final work = state.paths.workDir;
    if (db == null || work == null) return null;
    return SubsetUpdateFlow(
      subsetPath: db,
      workDir: work,
      indexDir: state.paths.indexDir,
      updateSource: state.settings.updateSource,
      updateFolder: state.settings.updateFolder,
    );
  }

  /// מתחיל להאזין ל-[stream]. המסך עובר למסך ההתקדמות בעצמו.
  void start(
    String title,
    Stream<FlowProgress> stream, {
    bool clearsUpdateNotice = false,
    Future<void> Function()? onSuccess,
  }) {
    _title = title;
    _progress = null;
    _error = null;
    _cancelled = false;
    _committing = false;
    _active = true;
    _notify();
    var failed = false;
    _flow = stream.listen(
      (event) {
        if (event.committing) _committing = true;
        _progress = event;
        _notify();
      },
      onError: (Object error) {
        failed = true;
        ErrorLog.instance.record('הפעולה נכשלה: $error');
        // החריגה הגולמית (שמות טבלאות, patch, סוגי חריגות) נשארת ביומן.
        _error = userFacingError(
          error,
          fallback: 'הפעולה לא הושלמה. אפשר לנסות שוב, ואם זה חוזר — '
              'לשלוח דיווח תקלה ממסך ההגדרות.',
        );
        _notify();
      },
      onDone: () {
        _flow = null;
        _active = false;
        // העדכון הוחל — "יש עדכון זמין" כבר אינו נכון.
        if (clearsUpdateNotice && !failed) _updateNotice = null;
        _notify();
        if (!failed && !_cancelled && onSuccess != null) {
          // פעולת המשך אינה רשאית להפיל את מה שכבר הצליח — רק ליומן.
          unawaited(onSuccess().catchError((Object e) {
            ErrorLog.instance.record('פעולת ההמשך נכשלה: $e');
          }));
        }
        _afterLibraryChanged();
      },
    );
  }

  Future<void> cancel() async {
    final flow = _flow;
    if (flow == null || _cancelled || _committing) return;
    _cancelled = true;
    _error = 'הפעולה בוטלה.';
    _notify();
    // הסרגל נשאר נעול עד שהביטול באמת הסתיים, והספרייה נקראת מחדש: ייתכן
    // שחלק מהעבודה כבר נכתב לפני שהביטול תפס.
    await flow.cancel();
    _flow = null;
    _active = false;
    _notify();
    _afterLibraryChanged();
  }

  /// הספרייה אולי השתנתה — הספירות והקטלוג נקראים ממנה מחדש.
  void _afterLibraryChanged() {
    if (_disposed) return;
    unawaited(loadStats());
    state.setCatalog(null);
  }

  // ── ספירות ─────────────────────────────────────────────────────

  Future<void> loadStats() async {
    final path = state.paths.libraryDbPath;
    if (path == null || !File(path).existsSync()) return;
    await for (final event in runJob(statsEntry, path)) {
      // ספירה של ספרייה שכבר הוחלפה בינתיים אינה נכונה לאף מסך.
      if (event is JobDone && !_disposed && state.paths.libraryDbPath == path) {
        state.setStats(event.result! as LibraryStats);
      }
    }
  }

  // ── בדיקת עדכונים לספרייה ──────────────────────────────────────

  var _checking = false;
  String? _updateNotice;

  bool get checking => _checking;
  String? get updateNotice => _updateNotice;

  /// בודק אם יש עדכון. מחזיר תוכנית שצריך להריץ, או `null` כשאין מה
  /// להריץ — ואז ההודעה במסך הבית כבר מעודכנת.
  Future<LibraryUpdatePlan?> checkUpdates() async {
    // לפני המחיקה הראשונה הספרייה עדיין של אוצריא, והזרימה מסרבת לעדכן
    // אותה — "יש עדכון" כאן היה מבטיח משהו שלא יקרה.
    if (_checking || busy || !state.hasSubset) return null;
    final flow = buildFlow();
    if (flow == null) return null;
    _checking = true;
    _notify();
    try {
      final plan = await flow.check();
      switch (plan.kind) {
        case LibraryUpdatePlanKind.none:
          _updateNotice = null;
          return null;
        case LibraryUpdatePlanKind.blocked:
          // הסיבה מהמתכנן מדברת על סכמות ועל DB — ליומן, לא למסך.
          ErrorLog.instance.record('העדכון חסום: ${plan.reason}');
          _updateNotice = 'העדכון אינו זמין כרגע';
          return null;
        case LibraryUpdatePlanKind.delta:
        case LibraryUpdatePlanKind.fullDownload:
          _updateNotice = 'יש עדכון זמין';
          return plan;
      }
    } catch (e) {
      ErrorLog.instance.record('בדיקת העדכונים נכשלה: $e');
      _updateNotice = userFacingError(e, fallback: 'בדיקת העדכונים נכשלה');
      return null;
    } finally {
      _checking = false;
      _notify();
    }
  }

  // ── עדכון התוכנה עצמה ──────────────────────────────────────────

  AppRelease? _appUpdate;
  AppRelease? get appUpdate => _appUpdate;

  /// בדיקה אחת בעלייה, ברקע. כשל מוחזר כ-`null` ונשאר שקט — מי שבא
  /// לגזום ספרים לא אמור לראות הודעת שגיאה על משהו שלא ביקש.
  Future<void> checkAppUpdate() async {
    final release = await appUpdater.check();
    if (release == null) return;
    _appUpdate = release;
    _notify();
  }

  void clearAppUpdate() {
    _appUpdate = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_flow?.cancel());
    super.dispose();
  }
}

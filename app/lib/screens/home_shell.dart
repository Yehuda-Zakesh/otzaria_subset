import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:seforim_library_updater/seforim_library_updater.dart';

import '../jobs/jobs.dart';
import '../main.dart';
import '../services/app_updater.dart';
import '../services/error_report.dart';
import '../services/otzaria_install.dart';
import '../services/update_flow.dart';
import '../theme.dart';
import '../widgets/app_update.dart';
import '../widgets/disclaimer.dart';
import '../widgets/format.dart';
import '../widgets/update_guard.dart';
import 'book_selection_screen.dart';
import 'home_screen.dart';
import 'progress_screen.dart';
import 'settings_screen.dart';

enum _View { home, books, progress, settings }

/// המעטפת: ניווט, והפעלת הפעולות הארוכות.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  var _view = _View.home;
  var _cancelled = false;
  var _checking = false;
  String? _updateNotice;
  AppRelease? _appUpdate;
  String? _progressTitle;
  FlowProgress? _progress;
  String? _flowError;
  StreamSubscription<FlowProgress>? _flow;

  /// פעולה על הספרייה בתהליך — מהלחיצה הראשונה (עוד לפני הדיאלוגים)
  /// ועד שהזרם נסגר באמת. בלי זה לחיצה כפולה, או בדיקת עדכונים ברקע
  /// בזמן גזימה, היו מריצות שתי פעולות על אותו קובץ.
  var _launching = false;
  var _flowActive = false;

  /// נדבק עד סוף הזרימה: אחרי נקודת האל-חזור אין ביטול — ראו
  /// `FlowProgress.committing`.
  var _committing = false;

  /// הספרייה שהמצב הנוכחי (ספירות, קטלוג) נקרא ממנה.
  String? _libraryPath;
  var _libraryPathKnown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_showDisclaimerIfNeeded());
      unawaited(_loadStats());
      unawaited(_checkAppUpdate());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // החלפת ספרייה בהגדרות: הקטלוג והספירות של הקודמת אסור שיישארו —
    // בחירה על קטלוג ישן הייתה נגזמת לפי מזהים של ספרייה אחרת.
    final path = _state.paths.libraryDbPath;
    if (!_libraryPathKnown) {
      _libraryPathKnown = true;
      _libraryPath = path;
      return;
    }
    if (path == _libraryPath) return;
    _libraryPath = path;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _state
        ..setCatalog(null)
        ..setStats(null);
      unawaited(_loadStats());
    });
  }

  @override
  void dispose() {
    unawaited(_flow?.cancel());
    super.dispose();
  }

  AppState get _state => AppScope.of(context);

  bool get _busy => _launching || _flowActive;

  /// ההבהרה מוצגת פעם אחת, לפני שהמשתמש נוגע במשהו — ראו kDisclaimer.
  Future<void> _showDisclaimerIfNeeded() async {
    if (_state.settings.disclaimerAccepted) return;
    if (!await showDisclaimerDialog(context)) return;
    if (!mounted) return;
    await _state.saveSettings(
      _state.settings.copyWith(disclaimerAccepted: true),
    );
  }

  SubsetUpdateFlow? _buildFlow() {
    final db = _state.paths.libraryDbPath;
    final work = _state.paths.workDir;
    if (db == null || work == null) return null;
    return SubsetUpdateFlow(
      subsetPath: db,
      workDir: work,
      indexDir: _state.paths.indexDir,
      updateSource: _state.settings.updateSource,
      updateFolder: _state.settings.updateFolder,
    );
  }

  Future<void> _loadStats() async {
    final state = _state;
    final path = state.paths.libraryDbPath;
    if (path == null || !File(path).existsSync()) return;
    await for (final event in runJob(statsEntry, path)) {
      // ספירה של ספרייה שכבר הוחלפה בינתיים אינה נכונה לאף מסך.
      if (event is JobDone && state.paths.libraryDbPath == path) {
        state.setStats(event.result! as LibraryStats);
      }
    }
  }

  // ── עדכון התוכנה עצמה ────────────────────────────────────────────

  /// בדיקה אחת בעלייה, ברקע. כשל מוחזר כ-`null` ונשאר שקט — מי שבא
  /// לגזום ספרים לא אמור לראות הודעת שגיאה על משהו שלא ביקש.
  Future<void> _checkAppUpdate() async {
    final release = await const AppUpdater().check();
    if (!mounted || release == null) return;
    setState(() => _appUpdate = release);
  }

  /// ההורדה מחליפה את התוכנה שרצה כרגע ומפעילה אותה מחדש, ולכן היא
  /// זמינה רק מהמסך הראשי — לא באמצע גזימה או עדכון של הספרייה.
  Future<void> _installAppUpdate() async {
    final release = _appUpdate;
    // עדכון התוכנה סוגר אותה — אסור באמצע פעולה על הספרייה.
    if (release == null || _busy) return;
    if (!await showAppUpdateDialog(context, release)) return;
    if (!mounted) return;
    setState(() => _appUpdate = null);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('העדכון לא הושלם'),
        content: const Text(
          'לא הצלחנו להוריד את הגרסה החדשה. לא נגענו בספרייה שלך, ואפשר '
          'לנסות שוב מאוחר יותר.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('הבנתי'),
          ),
        ],
      ),
    );
  }

  // ── בדיקת עדכונים ────────────────────────────────────────────────

  Future<void> _checkUpdates() async {
    // לפני המחיקה הראשונה הספרייה עדיין של אוצריא, והזרימה מסרבת לעדכן
    // אותה — "יש עדכון" כאן היה מבטיח משהו שלא יקרה.
    if (_checking || _busy || !_state.hasSubset) return;
    final flow = _buildFlow();
    if (flow == null) return;
    setState(() => _checking = true);
    try {
      final plan = await flow.check();
      if (!mounted) return;
      switch (plan.kind) {
        case LibraryUpdatePlanKind.none:
          setState(() => _updateNotice = null);
        case LibraryUpdatePlanKind.blocked:
          // הסיבה מהמתכנן מדברת על סכמות ועל DB — ליומן, לא למסך.
          ErrorLog.instance.record('העדכון חסום: ${plan.reason}');
          setState(() => _updateNotice = 'העדכון אינו זמין כרגע');
        case LibraryUpdatePlanKind.delta:
        case LibraryUpdatePlanKind.fullDownload:
          setState(() => _updateNotice = 'יש עדכון זמין');
          await _runUpdate(flow, plan);
      }
    } catch (e) {
      ErrorLog.instance.record('בדיקת העדכונים נכשלה: $e');
      if (mounted) {
        setState(
          () => _updateNotice =
              userFacingError(e, fallback: 'בדיקת העדכונים נכשלה'),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _runUpdate(SubsetUpdateFlow flow, LibraryUpdatePlan plan) async {
    final profile = _state.profile;
    if (profile == null || _busy) return;
    _launching = true;
    try {
      if (!await _confirmOtzariaClosed()) return;
      if (!await _confirmGuard()) return;
      if (!mounted) return;
    } finally {
      _launching = false;
    }
    _startFlow(
      'מעדכן את הספרייה',
      clearsUpdateNotice: true,
      flow.run(
        plan: plan,
        profile: profile,
        spec: _state.spec,
        isCancelled: () => _cancelled,
        onProfile: _state.saveProfile,
        onOutcome: (outcome) {
          _state.saveProfile(outcome.profile);
          _state.setPendingAcquisition(outcome.pendingAcquisition);
        },
      ),
    );
  }

  // ── גזימה ────────────────────────────────────────────────────────

  Future<void> _applySelection(SubsetSpec spec, int? estimatedBytes) async {
    final flow = _buildFlow();
    final profile = _state.profile;
    if (flow == null || profile == null || _busy) return;
    _launching = true;
    try {
      if (!await _confirmOtzariaClosed()) return;
      if (!await _confirmGuard()) return;
      if (!mounted || !await _confirmPrune(spec)) return;
      if (!mounted) return;
    } finally {
      _launching = false;
    }
    _state.setCatalog(null);
    _startFlow(
      'מעדכן את הספרייה',
      flow.prune(
        profile: profile,
        spec: spec,
        estimatedBytes: estimatedBytes,
        isCancelled: () => _cancelled,
        onProfile: _state.saveProfile,
        onOutcome: (outcome) => _state.saveProfile(outcome.profile),
      ),
    );
  }

  /// אישור לפני פעולה בלתי הפיכה.
  ///
  /// הספרים שסומנו נמחקים מהמחשב, ואין דרך להחזיר אותם בלי להוריד את
  /// הספרייה שוב. זה הדבר היחיד כאן שהמשתמש **חייב** לדעת לפני שהוא
  /// מאשר.
  Future<bool> _confirmPrune(SubsetSpec spec) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('למחוק את הספרים שסימנת?'),
        content: const SizedBox(
          width: 460,
          child: Text(
            'הספרים שסימנת יימחקו מהמחשב. כדי להחזיר אותם צריך להוריד '
            'את הספרייה מחדש.\n\n$kDisclaimer',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('חזרה'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('כן, להמשיך'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  /// אוצריא חייבת להיות סגורה.
  ///
  /// הגזימה מחליפה את קובץ הספרייה. אוצריא פתוחה מחזיקה אותו פתוח
  /// ב-SQLite, וההחלפה מתחת לרגליה משאירה אותה עם קובץ שנעלם — במקרה
  /// הטוב שגיאה, במקרה הרע `-wal` יתום שמבלבל את הפתיחה הבאה.
  Future<bool> _confirmOtzariaClosed() async {
    if (!await const OtzariaInstallLocator().isOtzariaRunning()) return true;
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('אוצריא פתוחה'),
        content: const Text(
          'צריך לסגור את אוצריא לפני שינוי הספרייה, ואז לנסות שוב.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('הבנתי'),
          ),
        ],
      ),
    );
    return false;
  }

  /// בדיקה חוזרת של הגדרות אוצריא לפני כל פעולה שנוגעת בספרייה.
  ///
  /// אוצריא מוחקת ספרייה חלקית ברגע שהעדכון האוטומטי שלה רץ עליה, ולכן
  /// לא מספיק לבדוק פעם אחת בהתקנה — המשתמש עלול להחזיר את ההגדרה.
  Future<bool> _confirmGuard() async {
    await _state.refreshOtzaria();
    final settings = _state.otzariaUpdates;
    if (settings == null || settings.isDisabled) return true;
    if (!mounted) return false;
    return showUpdateGuardDialog(context, settings);
  }

  // ── הרצה ─────────────────────────────────────────────────────────

  void _startFlow(
    String title,
    Stream<FlowProgress> stream, {
    bool clearsUpdateNotice = false,
  }) {
    setState(() {
      _view = _View.progress;
      _progressTitle = title;
      _progress = null;
      _flowError = null;
      _cancelled = false;
      _committing = false;
      _flowActive = true;
    });
    var failed = false;
    _flow = stream.listen(
      (event) {
        if (event.committing) _committing = true;
        if (mounted) setState(() => _progress = event);
      },
      onError: (Object error) {
        failed = true;
        ErrorLog.instance.record('הפעולה נכשלה: $error');
        if (!mounted) return;
        // החריגה הגולמית (שמות טבלאות, patch, סוגי חריגות) נשארת ביומן.
        setState(
          () => _flowError = userFacingError(
            error,
            fallback: 'הפעולה לא הושלמה. אפשר לנסות שוב, ואם זה חוזר — '
                'לשלוח דיווח תקלה ממסך ההגדרות.',
          ),
        );
      },
      onDone: () {
        _flow = null;
        if (!mounted) return;
        setState(() {
          _flowActive = false;
          // העדכון הוחל — "יש עדכון זמין" כבר אינו נכון.
          if (clearsUpdateNotice && !failed) _updateNotice = null;
        });
        _afterLibraryChanged();
      },
    );
  }

  /// הספרייה אולי השתנתה — הספירות והקטלוג נקראים ממנה מחדש.
  void _afterLibraryChanged() {
    unawaited(_loadStats());
    _state.setCatalog(null);
  }

  Future<void> _cancel() async {
    final flow = _flow;
    if (flow == null || _cancelled || _committing) return;
    _cancelled = true;
    setState(() => _flowError = 'הפעולה בוטלה.');
    // הסרגל נשאר נעול עד שהביטול באמת הסתיים, והספרייה נקראת מחדש: ייתכן
    // שחלק מהעבודה כבר נכתב לפני שהביטול תפס.
    await flow.cancel();
    _flow = null;
    if (!mounted) return;
    setState(() => _flowActive = false);
    _afterLibraryChanged();
  }

  // ── תצוגה ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // גם אחרי "בוטלה" או שגיאה — כל עוד הזרם לא נסגר, העבודה עוד רצה.
    final busy = _busy ||
        (_view == _View.progress &&
            _flowError == null &&
            _progress?.stage != FlowStage.done);

    final surfaces = AppSurfaces.of(context);

    return Scaffold(
      // רקע אחיד. קודם היה כאן גרדיאנט שנסחף לכחלחל, ועל רקע נייח
      // קל יותר לראות שהמשטח הלבן הוא שכבה נפרדת.
      backgroundColor: surfaces.canvas,
      body: Row(
        children: [
          _Sidebar(
            current: _view,
            enabled: !busy,
            onSelect: (view) => setState(() => _view = view),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 18, 18, 18),
              child: Container(
                decoration: BoxDecoration(
                  color: surfaces.panel,
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: surfaces.panelBorder),
                  boxShadow: AppShadows.soft,
                ),
                clipBehavior: Clip.antiAlias,
                child: _body(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() => switch (_view) {
        _View.home => HomeScreen(
            onChooseBooks: () => setState(() => _view = _View.books),
            onCheckUpdates: _checkUpdates,
            appUpdate: _appUpdate,
            onInstallAppUpdate: _installAppUpdate,
            updateNotice: _updateNotice,
            checking: _checking,
          ),
        _View.books => BookSelectionScreen(onApply: _applySelection),
        _View.settings => const SettingsScreen(),
        _View.progress => ProgressScreen(
            title: _progressTitle ?? '',
            progress: _progress,
            error: _flowError,
            onCancel: _committing ? null : () => unawaited(_cancel()),
            onClose: () => setState(() => _view = _View.home),
          ),
      };
}

/// סרגל צד משלנו, בגוון אינדיגו רך.
///
/// ‏`NavigationRail` הסטנדרטי נראה כמו כל אפליקציית Material, וכאן דווקא
/// חשוב שהתוכנה לא תתבלבל עם אוצריא — ראו `AppColors`. הזהות באה מהגוון
/// ולא מכהות: סרגל כמעט־שחור על רקע כמעט־לבן משך את העין יותר מהתוכן
/// עצמו, והרי הוא רק ניווט.
class _Sidebar extends StatelessWidget {
  final _View current;
  final bool enabled;
  final ValueChanged<_View> onSelect;

  const _Sidebar({
    required this.current,
    required this.enabled,
    required this.onSelect,
  });

  static const List<({_View view, IconData icon, String label})> _items = [
    (view: _View.home, icon: Icons.auto_awesome_rounded, label: 'הספרייה'),
    (view: _View.books, icon: Icons.checklist_rounded, label: 'ניהול ספרים'),
    (view: _View.settings, icon: Icons.tune_rounded, label: 'הגדרות'),
  ];

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    return Container(
      width: 170,
      margin: const EdgeInsets.fromLTRB(18, 18, 0, 18),
      decoration: BoxDecoration(
        color: surfaces.rail,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: surfaces.railBorder),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 18, 14, 18),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: AppTheme.hero(context),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(
                  Icons.auto_stories_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'ספרייה',
                style: TextStyle(
                  color: surfaces.railInk,
                  fontSize: 12,
                  letterSpacing: 0.2,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 18),
              for (final item in _items)
                _SidebarItem(
                  icon: item.icon,
                  label: item.label,
                  // מסך ההתקדמות אינו יעד בפני עצמו — הוא מוצג במקום
                  // "הספרייה", ולכן זה מה שנראה מסומן.
                  selected: current == item.view ||
                      (item.view == _View.home && current == _View.progress),
                  onTap: enabled ? () => onSelect(item.view) : null,
                ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: AppTheme.tint(
                    context,
                    AppColors.accent,
                    AppColors.accentSoft,
                  ),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'עדכון מבוקר',
                  style: TextStyle(
                    color: AppTheme.readable(context, AppColors.accent),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    // הנבחר מסומן בגוון ובמשקל גופן, לא בהיפוך צבעים — הבדל עדין מספיק
    // כדי לראות היכן אנחנו, בלי כתם כהה שקופץ מהסרגל.
    final ink = selected ? surfaces.railInkSelected : surfaces.railInk;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Material(
        color: selected ? surfaces.railSelected : Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
            child: Opacity(
              opacity: onTap == null ? 0.4 : 1,
              child: Column(
                children: [
                  Icon(icon, color: ink, size: 24),
                  const SizedBox(height: 7),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: ink,
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

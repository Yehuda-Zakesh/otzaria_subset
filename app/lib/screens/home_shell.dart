import 'dart:async';

import 'package:flutter/material.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:seforim_library_updater/seforim_library_updater.dart';

import '../main.dart';
import '../services/error_report.dart';
import '../services/mirror_builder.dart';
import '../services/otzaria_install.dart';
import '../services/update_flow.dart';
import '../state/app_settings.dart';
import '../state/flow_controller.dart';
import '../theme.dart';
import '../widgets/app_update.dart';
import '../widgets/disclaimer.dart';
import '../widgets/format.dart';
import '../widgets/update_guard.dart';
import 'book_selection_screen.dart';
import 'home_screen.dart';
import 'progress_screen.dart';
import 'restore_screen.dart';
import 'settings_screen.dart';

enum _View { home, books, restore, progress, settings }

/// המעטפת: ניווט, והדיאלוגים שלפני כל פעולה ארוכה.
///
/// הפעולה עצמה — המנעולים, הביטול, ההתקדמות — יושבת ב-[FlowController].
/// כאן נשאר רק מה שצריך `BuildContext`.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  var _view = _View.home;
  FlowController? _controllerOrNull;

  /// הספרייה שהמצב הנוכחי (ספירות, קטלוג) נקרא ממנה.
  String? _libraryPath;
  var _libraryPathKnown = false;

  FlowController get _flow => _controllerOrNull!;
  AppState get _state => AppScope.of(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controllerOrNull == null) {
      // נוצר כאן ולא ב-initState: הוא צריך את AppState מה-AppScope.
      _controllerOrNull = FlowController(_state)..addListener(_onFlow);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_showDisclaimerIfNeeded());
        unawaited(_flow.loadStats());
        unawaited(_flow.checkAppUpdate());
      });
    }
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
      unawaited(_flow.loadStats());
    });
  }

  void _onFlow() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controllerOrNull
      ?..removeListener(_onFlow)
      ..dispose();
    super.dispose();
  }

  /// ההבהרה מוצגת פעם אחת, לפני שהמשתמש נוגע במשהו — ראו kDisclaimer.
  Future<void> _showDisclaimerIfNeeded() async {
    if (_state.settings.disclaimerAccepted) return;
    if (!await showDisclaimerDialog(context)) return;
    if (!mounted) return;
    await _state.saveSettings(
      _state.settings.copyWith(disclaimerAccepted: true),
    );
  }

  // ── עדכון התוכנה עצמה ────────────────────────────────────────────

  /// ההורדה מחליפה את התוכנה שרצה כרגע ומפעילה אותה מחדש, ולכן היא
  /// זמינה רק מהמסך הראשי — לא באמצע גזימה או עדכון של הספרייה.
  Future<void> _installAppUpdate() async {
    final release = _flow.appUpdate;
    // עדכון התוכנה סוגר אותה — אסור באמצע פעולה על הספרייה.
    if (release == null || _flow.busy) return;
    if (!await showAppUpdateDialog(context, release)) return;
    if (!mounted) return;
    _flow.clearAppUpdate();
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
    final plan = await _flow.checkUpdates();
    if (plan == null || !mounted) return;
    await _runUpdate(plan);
  }

  Future<void> _runUpdate(LibraryUpdatePlan plan) async {
    final flow = _flow.buildFlow();
    final profile = _state.profile;
    if (flow == null || profile == null) return;
    final go = await _flow.guardLaunch(() async {
      if (!await _confirmOtzariaClosed()) return false;
      if (!await _confirmGuard()) return false;
      return mounted;
    });
    if (!go || !mounted) return;
    _start(
      'מעדכן את הספרייה',
      clearsUpdateNotice: true,
      onSuccess: _refreshDriveStatus(),
      flow.run(
        plan: plan,
        profile: profile,
        spec: _state.spec,
        isCancelled: () => _flow.cancelled,
        onProfile: _state.saveProfile,
        onOutcome: (outcome) => _state.saveProfile(outcome.profile),
        onFullCatalog: _state.saveCatalogSnapshot,
      ),
    );
  }

  /// מחשב שהתעדכן מכונן מרענן עליו את המצב שלו — אחרת המחשב המחובר היה
  /// מוריד בפעם הבאה שוב את מה שכבר הוחל כאן. `null` כשאין כונן.
  Future<void> Function()? _refreshDriveStatus() {
    final folder = _state.settings.updateSource == UpdateSource.folder
        ? _state.settings.updateFolder
        : null;
    if (folder == null || folder.isEmpty) return null;
    final db = _state.paths.libraryDbPath;
    return () => OfflineComputerStatus.capture(db).writeTo(folder);
  }

  // ── גזימה ────────────────────────────────────────────────────────

  Future<void> _applySelection(SubsetSpec spec, int? estimatedBytes) async {
    final flow = _flow.buildFlow();
    final profile = _state.profile;
    if (flow == null || profile == null) return;
    final go = await _flow.guardLaunch(() async {
      if (!await _confirmOtzariaClosed()) return false;
      if (!await _confirmGuard()) return false;
      if (!mounted || !await _confirmPrune(spec)) return false;
      return mounted;
    });
    if (!go || !mounted) return;
    // לפני הגזימה הראשונה הקטלוג שבמסך הוא של הספרייה המלאה — ההזדמנות
    // היחידה לשמור אותו, כדי שאפשר יהיה להחזיר אחר כך את מה שנמחק.
    final catalog = _state.catalog;
    if (!profile.categoriesPruned && catalog != null) {
      _state.saveCatalogSnapshot(catalog);
    }
    _state.setCatalog(null);
    _start(
      'מעדכן את הספרייה',
      flow.prune(
        profile: profile,
        spec: spec,
        estimatedBytes: estimatedBytes,
        isCancelled: () => _flow.cancelled,
        onProfile: _state.saveProfile,
        onOutcome: (outcome) => _state.saveProfile(outcome.profile),
      ),
    );
  }

  // ── בנייה ממסד מלא: החזרה, ספרים ממתינים, בחירה מיובאת ─────────────

  /// מוריד את הספרייה המלאה ובונה ממנה לפי [spec].
  ///
  /// זה המסלול היחיד שמביא ספר שאינו על הדיסק — עדכון נושא רק את מה
  /// שהשתנה (§5). התוכנית נבדקת **לפני** הדיאלוגים, כדי שהמשתמש יראה
  /// כמה יורד לפני שהוא מאשר.
  Future<void> _rebuildFromFull(SubsetSpec spec,
      {required String title}) async {
    final flow = _flow.buildFlow();
    final profile = _state.profile;
    if (flow == null || profile == null || _flow.busy) return;
    LibraryUpdatePlan plan;
    try {
      plan = await flow.check(forceFull: true);
    } catch (e) {
      ErrorLog.instance.record('בדיקת ההורדה המלאה נכשלה: $e');
      if (mounted) {
        await _info(
          'לא הצלחנו להתחבר',
          userFacingError(e, fallback: 'אפשר לנסות שוב מאוחר יותר.'),
        );
      }
      return;
    }
    if (!mounted) return;
    final asset = plan.fullDbAsset;
    if (plan.kind != LibraryUpdatePlanKind.fullDownload || asset == null) {
      ErrorLog.instance.record('הורדה מלאה אינה זמינה: ${plan.reason}');
      await _info(
        'הספרייה המלאה אינה זמינה כרגע',
        'אפשר לנסות שוב מאוחר יותר.',
      );
      return;
    }
    final go = await _flow.guardLaunch(() async {
      if (!await _confirmOtzariaClosed()) return false;
      if (!await _confirmGuard()) return false;
      if (!mounted || !await _confirmFullDownload(asset.size)) return false;
      return mounted;
    });
    if (!go || !mounted) return;
    _state.setCatalog(null);
    _start(
      title,
      onSuccess: _refreshDriveStatus(),
      flow.run(
        plan: plan,
        profile: profile,
        spec: spec,
        isCancelled: () => _flow.cancelled,
        onProfile: _state.saveProfile,
        onOutcome: (outcome) => _state.saveProfile(outcome.profile),
        onFullCatalog: _state.saveCatalogSnapshot,
      ),
    );
  }

  Future<bool> _confirmFullDownload(int bytes) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('להוריד את הספרייה המלאה?'),
        content: SizedBox(
          width: 460,
          child: Text(
            'כדי להביא ספרים שאינם במחשב צריך להוריד את הספרייה המלאה פעם '
            'אחת${bytes > 0 ? ' (בערך ${formatBytes(bytes)})' : ''}. בזמן '
            'הבנייה נדרש מקום פנוי זמני גדול, והוא מתפנה בסוף. הספרים '
            'שבחרת למחוק יישארו מחוקים.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('חזרה'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('להוריד'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  /// בחירה שיובאה ממחשב אחר.
  ///
  /// כשהיא רק מצמצמת (כל מה שהיא שומרת כבר כאן) — גזימה רגילה, בלי
  /// הורדה. כשהיא מרחיבה, או שאי אפשר לדעת — בנייה ממסד מלא.
  Future<void> _applyImported(SubsetSpec spec) async {
    final narrowsOnly = importNarrowsOnly(
      hasSubset: _state.hasSubset,
      snapshot: _state.catalogSnapshot,
      current: _state.spec,
      imported: spec,
    );
    if (narrowsOnly) {
      await _applySelection(spec, null);
    } else {
      await _rebuildFromFull(spec, title: 'מחיל את הבחירה');
    }
  }

  Future<void> _info(String title, String text) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('הבנתי'),
            ),
          ],
        ),
      );

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
            'הספרים שסימנת יימחקו מהמחשב. אפשר להחזיר אותם אחר כך במסך '
            '"החזרת ספרים", אבל ההחזרה מורידה את הספרייה המלאה.\n\n'
            '$kDisclaimer',
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

  void _start(
    String title,
    Stream<FlowProgress> stream, {
    bool clearsUpdateNotice = false,
    Future<void> Function()? onSuccess,
  }) {
    setState(() => _view = _View.progress);
    _flow.start(
      title,
      stream,
      clearsUpdateNotice: clearsUpdateNotice,
      onSuccess: onSuccess,
    );
  }

  // ── תצוגה ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final flow = _flow;
    // גם אחרי "בוטלה" או שגיאה — כל עוד הזרם לא נסגר, העבודה עוד רצה.
    final busy = flow.busy ||
        (_view == _View.progress &&
            flow.error == null &&
            flow.progress?.stage != FlowStage.done);

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
                child: _body(flow),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(FlowController flow) => switch (_view) {
        _View.home => HomeScreen(
            onChooseBooks: () => setState(() => _view = _View.books),
            onCheckUpdates: _checkUpdates,
            appUpdate: flow.appUpdate,
            onInstallAppUpdate: _installAppUpdate,
            updateNotice: flow.updateNotice,
            checking: flow.checking,
            onFetchPending: () =>
                _rebuildFromFull(_state.spec, title: 'מביא את הספרים'),
          ),
        _View.books => BookSelectionScreen(
            onApply: _applySelection,
            onImport: _applyImported,
          ),
        _View.restore => RestoreScreen(
            onRestore: (spec) => _rebuildFromFull(spec, title: 'מחזיר ספרים'),
            onFetchFull: () =>
                _rebuildFromFull(_state.spec, title: 'מוריד את הספרייה'),
          ),
        _View.settings => const SettingsScreen(),
        _View.progress => ProgressScreen(
            title: flow.title,
            progress: flow.progress,
            error: flow.error,
            onCancel: flow.committing ? null : () => unawaited(flow.cancel()),
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
    (view: _View.restore, icon: Icons.restore_rounded, label: 'החזרת ספרים'),
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

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:seforim_library_updater/seforim_library_updater.dart';

import '../jobs/jobs.dart';
import '../main.dart';
import '../services/otzaria_install.dart';
import '../services/update_flow.dart';
import '../widgets/disclaimer.dart';
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
  String? _progressTitle;
  FlowProgress? _progress;
  String? _flowError;
  StreamSubscription<FlowProgress>? _flow;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_showDisclaimerIfNeeded());
      unawaited(_loadStats());
    });
  }

  @override
  void dispose() {
    unawaited(_flow?.cancel());
    super.dispose();
  }

  AppState get _state => AppScope.of(context);

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
    final path = _state.paths.libraryDbPath;
    if (path == null || !File(path).existsSync()) return;
    await for (final event in runJob(statsEntry, path)) {
      if (event is JobDone) _state.setStats(event.result! as LibraryStats);
    }
  }

  // ── בדיקת עדכונים ────────────────────────────────────────────────

  Future<void> _checkUpdates() async {
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
          setState(() => _updateNotice = plan.reason ?? 'העדכון אינו זמין');
        case LibraryUpdatePlanKind.delta:
        case LibraryUpdatePlanKind.fullDownload:
          setState(() => _updateNotice = 'יש עדכון זמין');
          await _runUpdate(flow, plan);
      }
    } catch (e) {
      if (mounted) setState(() => _updateNotice = 'בדיקת העדכונים נכשלה');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _runUpdate(SubsetUpdateFlow flow, LibraryUpdatePlan plan) async {
    final profile = _state.profile;
    if (profile == null) return;
    if (!await _confirmOtzariaClosed()) return;
    if (!await _confirmGuard()) return;
    _startFlow(
      'מעדכן את הספרייה',
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
    if (flow == null || profile == null) return;
    if (!await _confirmOtzariaClosed()) return;
    if (!await _confirmGuard()) return;
    if (!await _confirmPrune(spec)) return;
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

  void _startFlow(String title, Stream<FlowProgress> stream) {
    setState(() {
      _view = _View.progress;
      _progressTitle = title;
      _progress = null;
      _flowError = null;
      _cancelled = false;
    });
    _flow = stream.listen(
      (event) => setState(() => _progress = event),
      onError: (Object error) => setState(() => _flowError = '$error'),
      onDone: () {
        unawaited(_loadStats());
        _state.setCatalog(null);
      },
    );
  }

  void _cancel() {
    _cancelled = true;
    unawaited(_flow?.cancel());
    setState(() => _flowError = 'הפעולה בוטלה.');
  }

  // ── תצוגה ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final busy = _view == _View.progress &&
        _flowError == null &&
        _progress?.stage != FlowStage.done;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFF7F5FD),
              Color(0xFFF2F1FB),
              Color(0xFFF5FAFF),
            ],
          ),
        ),
        child: Row(
          children: [
            _Sidebar(
              current: _view,
              enabled: !busy,
              onSelect: (view) => setState(() => _view = view),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 18, 18, 18),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(30),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFFCFBFF),
                      border: Border.all(
                        color: const Color(0xFFE7E0FB),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              const Color(0xFF2B2147).withValues(alpha: 0.06),
                          blurRadius: 24,
                          spreadRadius: 0,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: _body(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() => switch (_view) {
        _View.home => HomeScreen(
            onChooseBooks: () => setState(() => _view = _View.books),
            onCheckUpdates: _checkUpdates,
            updateNotice: _updateNotice,
            checking: _checking,
          ),
        _View.books => BookSelectionScreen(onApply: _applySelection),
        _View.settings => const SettingsScreen(),
        _View.progress => ProgressScreen(
            title: _progressTitle ?? '',
            progress: _progress,
            error: _flowError,
            onCancel: _cancel,
            onClose: () => setState(() => _view = _View.home),
          ),
      };
}

/// סרגל צד עם גרדיאנט.
///
/// ‏`NavigationRail` הסטנדרטי נראה כמו כל אפליקציית Material, וכאן דווקא
/// חשוב שהתוכנה לא תתבלבל עם אוצריא — ראו `AppColors`.
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
  Widget build(BuildContext context) => Container(
        width: 170,
        margin: const EdgeInsets.fromLTRB(18, 18, 0, 18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF3E2D78).withValues(alpha: 0.97),
              const Color(0xFF1F1B36).withValues(alpha: 0.98),
              const Color(0xFF151826).withValues(alpha: 0.98),
            ],
          ),
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF1A1530).withValues(alpha: 0.24),
              blurRadius: 28,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 18, 14, 18),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  child: const Icon(
                    Icons.auto_stories_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'ספרייה',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
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
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: const Text(
                    'עדכון מבוקר',
                    style: TextStyle(
                      color: Colors.white,
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
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Material(
          color: selected
              ? Colors.white.withValues(alpha: 0.19)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
              child: Opacity(
                opacity: onTap == null ? 0.45 : 1,
                child: Column(
                  children: [
                    Icon(icon, color: Colors.white, size: 24),
                    const SizedBox(height: 7),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
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

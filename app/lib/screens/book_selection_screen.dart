import 'dart:async';

import 'package:flutter/material.dart';
import 'package:otzaria_subset/otzaria_subset.dart';

import '../jobs/jobs.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/category_tree.dart';
import '../widgets/format.dart';

/// בחירת מה **למחוק** מהספרייה.
///
/// ## למה מסמנים מה יורד ולא מה נשאר
///
/// המשתמש פותח את התוכנה עם ספרייה מלאה שכבר יושבת אצלו, והפעולה
/// שהוא בא לעשות היא להוריד ממנה. סימון "מה להשאיר" היה מחייב אותו
/// לעבור על אלפי ספרים ולסמן את רובם. המנוע עדיין עובד עם כלל-שמירה,
/// וההיפוך נעשה ב-`keepSpecFor`.
///
/// ## למה יש כאן השהיה
///
/// כל סימון משנה את הבחירה, וכל בחירה נפתרת מול המסד — שאילתת `link`
/// על מסד של גיגה-בייטים. בלי השהיה, סימון קטגוריה גדולה היה מריץ
/// עשרות שאילתות כאלה ברצף. הפתירה רצה ב-`Isolate` כדי שהעץ יישאר מגיב.
class BookSelectionScreen extends StatefulWidget {
  final void Function(SubsetSpec spec, int? estimatedBytes) onApply;

  const BookSelectionScreen({super.key, required this.onApply});

  @override
  State<BookSelectionScreen> createState() => _BookSelectionScreenState();
}

class _BookSelectionScreenState extends State<BookSelectionScreen> {
  static const Duration _debounce = Duration(milliseconds: 450);

  RemovalSelection _removal = RemovalSelection.empty;
  SubsetPlan? _plan;
  Timer? _timer;
  StreamSubscription<JobEvent>? _running;
  var _loadingCatalog = false;
  var _estimating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCatalog());
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_running?.cancel());
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    final state = AppScope.of(context);
    if (state.catalog != null) return;
    final path = state.paths.libraryDbPath;
    if (path == null) return;
    setState(() => _loadingCatalog = true);
    await for (final event in runJob(catalogEntry, path)) {
      if (event is JobDone) state.setCatalog(event.result! as LibraryCatalog);
      if (event is JobFailed) state.setError(event.message);
    }
    if (!mounted) return;
    setState(() => _loadingCatalog = false);
  }

  void _onChanged(RemovalSelection removal) {
    setState(() => _removal = removal);
    _timer?.cancel();
    _timer = Timer(_debounce, _estimate);
  }

  SubsetSpec? _spec() {
    final catalog = AppScope.of(context).catalog;
    if (catalog == null) return null;
    return keepSpecFor(catalog, _removal);
  }

  Future<void> _estimate() async {
    final state = AppScope.of(context);
    final path = state.paths.libraryDbPath;
    final spec = _spec();
    if (path == null || spec == null) return;
    // הרצה קודמת כבר אינה רלוונטית — ביטול המנוי הורג את ה-`Isolate`
    // שלה, אחרת היו נצברים חישובים על בחירות ישנות.
    await _running?.cancel();
    if (!mounted) return;
    setState(() => _estimating = true);
    _running = runJob(resolveEntry, ResolveArgs(path, spec)).listen((event) {
      if (!mounted) return;
      if (event is JobDone) {
        setState(() {
          _plan = event.result! as SubsetPlan;
          _estimating = false;
        });
      }
      if (event is JobFailed) {
        setState(() => _estimating = false);
        state.setError(event.message);
      }
    });
  }

  /// כמה ספרים סומנו למחיקה, לפי העץ שבזיכרון.
  int _removedCount(LibraryCatalog catalog) {
    final removed = <int>{};
    for (final categoryId in _removal.categoryIds) {
      for (final book in catalog.booksUnder(categoryId)) {
        removed.add(book.id);
      }
    }
    removed.addAll(_removal.bookIds);
    return removed.length;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final catalog = state.catalog;

    if (_loadingCatalog || catalog == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final spec = _spec();
    return Column(
      children: [
        Expanded(
          child: CategoryTree(
            catalog: catalog,
            removal: _removal,
            onChanged: _onChanged,
          ),
        ),
        _SummaryBar(
          removedBooks: _removedCount(catalog),
          plan: _plan,
          estimating: _estimating,
          currentBytes: state.libraryBytes,
          onApply: _removal.isEmpty || spec == null
              ? null
              : () => widget.onApply(spec, _plan?.estimatedBytes),
        ),
      ],
    );
  }
}

/// הפס התחתון: כמה יימחק, כמה מקום יתפנה, ומה יישבר.
class _SummaryBar extends StatelessWidget {
  final int removedBooks;
  final SubsetPlan? plan;
  final bool estimating;
  final int currentBytes;
  final VoidCallback? onApply;

  const _SummaryBar({
    required this.removedBooks,
    required this.plan,
    required this.estimating,
    required this.currentBytes,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final current = plan;
    final freed = current == null
        ? 0
        : (currentBytes - current.estimatedBytes).clamp(0, currentBytes);

    final surfaces = AppSurfaces.of(context);
    return Container(
      decoration: BoxDecoration(
        color: surfaces.panel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        // קו הפרדה במקום צל שחור: הפס יושב מעל רשימה לבנה, וצל כהה
        // מתחתיו היה הכתם הכהה היחיד במסך.
        border: Border(top: BorderSide(color: surfaces.panelBorder)),
      ),
      padding: const EdgeInsets.fromLTRB(28, 18, 28, 18),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  removedBooks == 0
                      ? 'לא סומן דבר למחיקה'
                      : '${formatCount(removedBooks)} ספרים יימחקו',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 2),
                if (removedBooks > 0)
                  Text(
                    current == null
                        ? 'מחשב כמה מקום יתפנה…'
                        : 'יתפנו בערך ${formatBytes(freed)}',
                    style: TextStyle(
                      color: AppTheme.readable(context, AppColors.accent),
                    ),
                  ),
                if (current != null && current.hasSeveredLinks)
                  _SeveredNotice(plan: current),
              ],
            ),
          ),
          if (estimating)
            const Padding(
              padding: EdgeInsetsDirectional.only(end: 18),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          FilledButton.icon(
            onPressed: onApply,
            icon: const Icon(Icons.delete_sweep_rounded),
            label: const Text('מחיקת המסומנים'),
          ),
        ],
      ),
    );
  }
}

/// קישורים חוצי גבול. זה **כן** מעניין את המשתמש: מפרש שמצביע לספר
/// שנמחק פשוט לא יעבוד אצלו, וזה המחיר של הבחירה שלו.
class _SeveredNotice extends StatelessWidget {
  final SubsetPlan plan;

  const _SeveredNotice({required this.plan});

  @override
  Widget build(BuildContext context) => TextButton(
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('קישורים שלא יעבדו'),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${formatCount(plan.severedLinkCount)} קישורים מצביעים '
                    'לספרים שסימנת למחיקה, ולכן לא יעבדו. הספרים שאליהם '
                    'מצביעים הכי הרבה:',
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final target in plan.severedLinks.take(12))
                          ListTile(
                            dense: true,
                            title: Text(target.title),
                            subtitle: Text(
                              '${formatCount(target.linkCount)} קישורים · '
                              '${formatBytes(target.estimatedBytes)}',
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('סגור'),
              ),
            ],
          ),
        ),
        child: Text(
          '${formatCount(plan.severedLinkCount)} קישורים לא יעבדו — לפרטים',
          style: TextStyle(color: AppTheme.readable(context, AppColors.warm)),
        ),
      );
}

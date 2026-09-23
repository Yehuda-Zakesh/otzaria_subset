import 'dart:async';

import 'package:flutter/material.dart';
import 'package:otzaria_subset/otzaria_subset.dart';

import '../jobs/jobs.dart';
import '../main.dart';
import '../services/error_report.dart';
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
  var _catalogFailed = false;
  var _estimating = false;
  var _estimateFailed = false;

  /// מונה הרצות: תוצאה של אומדן שכבר הוחלף אינה נוגעת במסך.
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadCatalog());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_running?.cancel());
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    // שתי קריאות (initState וה-build) באותה מסגרת לא יריצו שתי טעינות.
    if (_loadingCatalog) return;
    final state = AppScope.of(context);
    if (state.catalog != null) return;
    final path = state.paths.libraryDbPath;
    if (path == null) return;
    setState(() {
      _loadingCatalog = true;
      _catalogFailed = false;
    });
    var failed = false;
    await for (final event in runJob(catalogEntry, path)) {
      if (event is JobDone) state.setCatalog(event.result! as LibraryCatalog);
      if (event is JobFailed) {
        // ההודעה הגולמית ליומן בלבד; בלי הדגל המסך היה מסתובב לנצח.
        ErrorLog.instance.record(event.message);
        state.setError(event.message);
        failed = true;
      }
    }
    if (!mounted) return;
    setState(() {
      _loadingCatalog = false;
      _catalogFailed = failed || state.catalog == null;
    });
  }

  void _onChanged(RemovalSelection removal) {
    // האומדן הקודם שייך לבחירה אחרת — אסור שיגיע לבדיקת המקום בגזימה.
    _generation++;
    setState(() {
      _removal = removal;
      _plan = null;
      _estimating = false;
      _estimateFailed = false;
    });
    _timer?.cancel();
    _timer = Timer(_debounce, _estimate);
  }

  SubsetSpec? _spec() {
    final state = AppScope.of(context);
    final catalog = state.catalog;
    if (catalog == null) return null;
    // הקטלוג נקרא מהספרייה שכבר נגזמה; בלי הכלל הקודם ענף שחלקו נמחק
    // בעבר נראה שלם, ובבנייה הבאה ממסד מלא מה שנמחק היה חוזר.
    return keepSpecFor(catalog, _removal, previous: state.spec);
  }

  Future<void> _estimate() async {
    if (!mounted) return;
    final state = AppScope.of(context);
    final path = state.paths.libraryDbPath;
    final spec = _spec();
    if (path == null || spec == null) return;
    final generation = _generation;
    // הרצה קודמת כבר אינה רלוונטית — ביטול המנוי הורג את ה-`Isolate`
    // שלה, אחרת היו נצברים חישובים על בחירות ישנות.
    final previous = _running;
    _running = null;
    await previous?.cancel();
    if (!mounted || generation != _generation) return;
    setState(() => _estimating = true);
    _running = runJob(resolveEntry, ResolveArgs(path, spec)).listen((event) {
      if (!mounted || generation != _generation) return;
      if (event is JobDone) {
        setState(() {
          _plan = event.result! as SubsetPlan;
          _estimating = false;
        });
      }
      if (event is JobFailed) {
        ErrorLog.instance.record(event.message);
        setState(() {
          _estimating = false;
          _estimateFailed = true;
        });
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

    // בלי ספרייה או אחרי כשל אין מה לטעון — ספינר כאן היה מסתובב לנצח.
    if (state.paths.libraryDbPath == null) {
      return const _Notice(
        icon: Icons.travel_explore_rounded,
        text: 'לא נמצאה ספריית אוצריא. אפשר להצביע עליה ידנית במסך ההגדרות.',
      );
    }
    if (_catalogFailed && !_loadingCatalog && catalog == null) {
      return _Notice(
        icon: Icons.error_outline_rounded,
        text: 'לא הצלחנו לקרוא את רשימת הספרים.',
        action: TextButton(
          onPressed: () => unawaited(_loadCatalog()),
          child: const Text('לנסות שוב'),
        ),
      );
    }
    if (_loadingCatalog || catalog == null) {
      // הקטלוג יכול להתאפס מבחוץ (אחרי גזימה או החלפת ספרייה) בזמן
      // שהמסך פתוח — בלי טעינה חוזרת הספינר היה נשאר לתמיד.
      if (!_loadingCatalog) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_loadCatalog());
        });
      }
      return const Center(child: CircularProgressIndicator());
    }

    final spec = _spec();
    final removedBooks = _removedCount(catalog);
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
          removedBooks: removedBooks,
          plan: _plan,
          estimating: _estimating,
          estimateFailed: _estimateFailed,
          currentBytes: state.libraryBytes,
          // סימון שאינו מוחק אף ספר (קטגוריה ריקה) אינו פעולה.
          onApply: removedBooks == 0 || spec == null
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
  final bool estimateFailed;
  final int currentBytes;
  final VoidCallback? onApply;

  const _SummaryBar({
    required this.removedBooks,
    required this.plan,
    required this.estimating,
    required this.estimateFailed,
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
                      : removedBooks == 1
                          ? 'ספר אחד יימחק'
                          : '${formatCount(removedBooks)} ספרים יימחקו',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 2),
                if (removedBooks > 0)
                  Text(
                    current == null && estimateFailed
                        ? 'לא הצלחנו לחשב כמה מקום יתפנה'
                        : current == null
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
                    '${plan.severedLinkCount == 1 ? 'קישור אחד מצביע' : '${formatCount(plan.severedLinkCount)} קישורים מצביעים'} '
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
                              '${formatQuantity(target.linkCount, one: 'קישור אחד', many: 'קישורים')} · '
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
          plan.severedLinkCount == 1
              ? 'קישור אחד לא יעבוד — לפרטים'
              : '${formatCount(plan.severedLinkCount)} קישורים לא יעבדו — לפרטים',
          style: TextStyle(color: AppTheme.readable(context, AppColors.warm)),
        ),
      );
}

/// הודעה במרכז המסך, במקום עץ שאין מה להציג בו.
class _Notice extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;

  const _Notice({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 36, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              Text(text, textAlign: TextAlign.center),
              if (action != null) ...[
                const SizedBox(height: 12),
                action!,
              ],
            ],
          ),
        ),
      );
}

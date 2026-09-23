import 'package:flutter/material.dart';
import 'package:otzaria_subset/otzaria_subset.dart';

import '../main.dart';
import '../theme.dart';
import '../widgets/category_tree.dart';
import '../widgets/format.dart';

/// החזרת ספרים שנמחקו.
///
/// ## למה העץ כאן בנוי מהקטלוג השמור ולא מהספרייה
///
/// הספרייה הגזומה כבר אינה יודעת מה היה בה: ספר שנמחק פשוט אינו שם.
/// הקטלוג המלא נשמר לפני הגזימה הראשונה (ובכל בנייה ממסד מלא), וממנו
/// נגזר מה אפשר להחזיר. ההחזרה עצמה דורשת את הספרייה המלאה — אין דרך
/// אחרת להשיג טקסט של ספר שאינו על הדיסק (§5).
class RestoreScreen extends StatefulWidget {
  /// מקבל את הכלל החדש (רחב מהנוכחי) ומפעיל בנייה ממסד מלא.
  final void Function(SubsetSpec spec) onRestore;

  /// בלי קטלוג שמור: הורדת הספרייה המלאה עם הבחירה הנוכחית, שבדרך גם
  /// שומרת את הקטלוג להבא.
  final VoidCallback onFetchFull;

  const RestoreScreen({
    super.key,
    required this.onRestore,
    required this.onFetchFull,
  });

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  // העץ משותף עם מסך המחיקה, ולכן הסימון שלו נקרא "הסרה" — כאן הוא
  // פשוט "מה להחזיר".
  RemovalSelection _marks = RemovalSelection.empty;

  /// נשמר לפי זהות הקלט: בניית תת-הקטלוג עוברת על כל הספרים.
  LibraryCatalog? _restorable;
  LibraryCatalog? _forSnapshot;
  SubsetSpec? _forSpec;

  LibraryCatalog _restorableFor(LibraryCatalog snapshot, SubsetSpec spec) {
    if (!identical(snapshot, _forSnapshot) || spec != _forSpec) {
      _forSnapshot = snapshot;
      _forSpec = spec;
      _restorable = restorableCatalog(snapshot, spec);
      _marks = RemovalSelection.empty;
    }
    return _restorable!;
  }

  RestoreSelection get _selection => RestoreSelection(
        categoryIds: _marks.categoryIds,
        bookIds: _marks.bookIds,
      );

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (!state.hasSubset) {
      return const _Notice(
        icon: Icons.inventory_2_outlined,
        text: 'עוד לא נמחקו ספרים מהספרייה, ולכן אין מה להחזיר.',
      );
    }
    final snapshot = state.catalogSnapshot;
    if (snapshot == null) {
      return _Notice(
        icon: Icons.history_rounded,
        text: 'רשימת הספרים שנמחקו אינה שמורה במחשב הזה, כי הם נמחקו בגרסה '
            'קודמת של התוכנה. אפשר להוריד את הספרייה המלאה פעם אחת — הבחירה '
            'שלך נשמרת, ומאז אפשר יהיה לבחור כאן מה להחזיר.',
        action: FilledButton.icon(
          onPressed: widget.onFetchFull,
          icon: const Icon(Icons.download_rounded),
          label: const Text('הורדת הספרייה המלאה'),
        ),
      );
    }

    final restorable = _restorableFor(snapshot, state.spec);
    if (restorable.books.isEmpty) {
      return const _Notice(
        icon: Icons.check_circle_outline_rounded,
        text: 'כל הספרים נמצאים בספרייה. אין מה להחזיר.',
      );
    }

    final restored = _restoredBooks(restorable);
    final bytes = restored.fold<int>(
      0,
      (sum, book) => sum + restorable.estimatedBytesOf(book),
    );
    return Column(
      children: [
        Expanded(
          child: CategoryTree(
            catalog: restorable,
            removal: _marks,
            checkboxLabel: 'להחזרה',
            onChanged: (marks) => setState(() => _marks = marks),
          ),
        ),
        _RestoreBar(
          count: restored.length,
          bytes: restorable.bytesPerLine > 0 ? bytes : null,
          onRestore: restored.isEmpty
              ? null
              : () => widget.onRestore(
                    restoreSpecFor(snapshot, state.spec, _selection),
                  ),
        ),
      ],
    );
  }

  /// הספרים שיחזרו לפי הסימון, מתוך מה שאפשר להחזיר בלבד.
  List<CatalogBook> _restoredBooks(LibraryCatalog restorable) {
    final ids = <int>{..._marks.bookIds};
    for (final categoryId in _marks.categoryIds) {
      for (final book in restorable.booksUnder(categoryId)) {
        ids.add(book.id);
      }
    }
    return [
      for (final id in ids)
        if (restorable.bookById(id) case final book?) book,
    ];
  }
}

class _RestoreBar extends StatelessWidget {
  final int count;

  /// `null` כשאין אומדן גודל — אז פשוט לא מציגים אותו.
  final int? bytes;
  final VoidCallback? onRestore;

  const _RestoreBar({
    required this.count,
    required this.bytes,
    required this.onRestore,
  });

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    final size = bytes;
    return Container(
      decoration: BoxDecoration(
        color: surfaces.panel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
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
                  count == 0
                      ? 'סמנו מה להחזיר'
                      : count == 1
                          ? 'ספר אחד יחזור'
                          : '${formatCount(count)} ספרים יחזרו',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  count > 0 && size != null
                      ? 'יתפסו בערך ${formatBytes(size)}. ההחזרה מורידה את '
                          'הספרייה המלאה פעם אחת.'
                      : 'ההחזרה מורידה את הספרייה המלאה פעם אחת.',
                  style: TextStyle(
                    color: AppTheme.readable(context, AppColors.accent),
                  ),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: onRestore,
            icon: const Icon(Icons.restore_rounded),
            label: const Text('החזרת המסומנים'),
          ),
        ],
      ),
    );
  }
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
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 36, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              Text(text, textAlign: TextAlign.center),
              if (action != null) ...[
                const SizedBox(height: 16),
                action!,
              ],
            ],
          ),
        ),
      );
}

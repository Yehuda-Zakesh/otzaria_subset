import 'package:flutter/material.dart';
import 'package:otzaria_subset/otzaria_subset.dart';

import 'format.dart';

/// מצב הסימון של צומת בעץ.
enum TriState { none, partial, all }

/// עץ הקטגוריות עם תיבות תלת-מצביות. **סימון פירושו מחיקה.**
///
/// ## למה המצב יושב כאן
///
/// המשתמש מסמן מה להוריד; המנוע צריך כלל של מה נשאר. [RemovalSelection]
/// הוא הצד של המשתמש, ו-`keepSpecFor` מתרגם. העץ מציג מצב **נגזר** —
/// קטגוריה מסומנת חלקית מפני שחלק מצאצאיה סומנו — והחישוב נעשה כאן לפי
/// הקטלוג שבזיכרון, בלי אף שאילתה למסד.
class CategoryTree extends StatefulWidget {
  final LibraryCatalog catalog;
  final RemovalSelection removal;
  final ValueChanged<RemovalSelection> onChanged;

  /// תווית נגישות לתיבות הסימון. העץ משמש גם למסכים שבהם סימון אינו
  /// מחיקה, ולכן המשמעות נקבעת בחוץ.
  final String? checkboxLabel;

  const CategoryTree({
    super.key,
    required this.catalog,
    required this.removal,
    required this.onChanged,
    this.checkboxLabel,
  });

  @override
  State<CategoryTree> createState() => _CategoryTreeState();
}

class _CategoryTreeState extends State<CategoryTree> {
  final Set<int> _expanded = {};

  /// קטגוריות שהמשתמש סגר בזמן חיפוש. בלי זה קטגוריה שנפתחה מאליה
  /// בחיפוש לא הייתה ניתנת לסגירה.
  final Set<int> _collapsed = {};
  String _query = '';

  /// מיון לפי גודל, מהגדול לקטן. ברירת המחדל היא סדר הספרייה, כי זה
  /// הסדר שהמשתמש מכיר.
  bool _bySize = false;

  // הרשימות הממוינות נשמרות לכל קטגוריה: מיון מחדש בכל בנייה של כל
  // שורה פתוחה היה מבוזבז, והגדלים אינם משתנים כל עוד הקטלוג אותו קטלוג.
  final Map<int, List<CatalogCategory>> _sortedChildren = {};
  final Map<int, List<CatalogBook>> _sortedBooks = {};
  List<CatalogCategory>? _sortedRoots;

  /// בלי כיול אין גדלים, ו-"0 B" בכל שורה היה מטעה יותר מהסתרה.
  bool get _sizesKnown => widget.catalog.bytesPerLine > 0;
  bool get _sorting => _bySize && _sizesKnown;

  // המצב הנגזר מחושב פעם אחת לכל בחירה ולא לכל שורה: חישוב לכל שורה
  // עובר על כל תת-העץ שלה, ועל אלפי ספרים זה ריבועי בכל בנייה.
  TreeMarks? _marks;
  final Map<int, bool> _matchCache = {};

  TreeMarks get _derived {
    final cached = _marks;
    if (cached != null &&
        identical(cached.catalog, widget.catalog) &&
        identical(cached.removal, widget.removal)) {
      return cached;
    }
    return _marks = TreeMarks(widget.catalog, widget.removal);
  }

  @override
  void didUpdateWidget(CategoryTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.catalog, widget.catalog)) {
      _matchCache.clear();
      _clearSorted();
    }
  }

  void _clearSorted() {
    _sortedChildren.clear();
    _sortedBooks.clear();
    _sortedRoots = null;
  }

  // ‏bytesUnder נשלף ממפה שהקטלוג בונה פעם אחת, ולכן המיון אינו סורק
  // תת-עצים. שובר השוויון הוא הסדר המקורי — List.sort אינו יציב.
  List<CatalogCategory> _orderCategories(List<CatalogCategory> list) {
    if (!_sorting || list.length < 2) return list;
    final catalog = widget.catalog;
    final index = {for (var i = 0; i < list.length; i++) list[i].id: i};
    return [...list]..sort((a, b) {
        final bySize =
            catalog.bytesUnder(b.id).compareTo(catalog.bytesUnder(a.id));
        return bySize != 0 ? bySize : index[a.id]!.compareTo(index[b.id]!);
      });
  }

  List<CatalogBook> _orderBooks(List<CatalogBook> list) {
    if (!_sorting || list.length < 2) return list;
    final catalog = widget.catalog;
    final index = {for (var i = 0; i < list.length; i++) list[i].id: i};
    return [...list]..sort((a, b) {
        final bySize =
            catalog.estimatedBytesOf(b).compareTo(catalog.estimatedBytesOf(a));
        return bySize != 0 ? bySize : index[a.id]!.compareTo(index[b.id]!);
      });
  }

  List<CatalogCategory> _childrenOf(int id) =>
      _sortedChildren[id] ??= _orderCategories(
        widget.catalog.childrenOf[id] ?? const <CatalogCategory>[],
      );

  List<CatalogBook> _booksOf(int id) => _sortedBooks[id] ??=
      _orderBooks(widget.catalog.booksOf[id] ?? const <CatalogBook>[]);

  @override
  Widget build(BuildContext context) {
    final roots = _visibleRoots();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  // בלי border מפורש — השדה מקבל את העיצוב הכללי
                  // מ-InputDecorationTheme ולא נראה שונה משאר האפליקציה.
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: 'חיפוש ספר או קטגוריה',
                    isDense: true,
                  ),
                  onChanged: (value) => setState(() {
                    _query = value.trim();
                    _matchCache.clear();
                    _collapsed.clear();
                  }),
                ),
              ),
              if (_sizesKnown) ...[
                const SizedBox(width: 8),
                IconButton(
                  key: const ValueKey('sort-by-size'),
                  isSelected: _bySize,
                  tooltip: _bySize ? 'מיון לפי סדר הספרייה' : 'מיון לפי גודל',
                  icon: const Icon(Icons.sort_rounded),
                  selectedIcon: const Icon(Icons.format_list_numbered_rounded),
                  onPressed: () => setState(() {
                    _bySize = !_bySize;
                    _clearSorted();
                  }),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: roots.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.search_off_rounded,
                        size: 32,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(height: 8),
                      // ספרייה ריקה אינה "אין תוצאות" — לא חיפשו כלום.
                      Text(_query.isEmpty ? 'אין ספרים בספרייה' : 'אין תוצאות'),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    for (final root in roots)
                      ..._rows(root, 0, filtering: _query.isNotEmpty),
                  ],
                ),
        ),
      ],
    );
  }

  /// בחיפוש מוצגות רק קטגוריות שיש תחתיהן התאמה, והן נפתחות מאליהן —
  /// אחרת המשתמש היה מקבל רשימה סגורה בלי לדעת מה בתוכה.
  List<CatalogCategory> _visibleRoots() =>
      (_sortedRoots ??= _orderCategories(widget.catalog.roots))
          .where((c) => _query.isEmpty || _matches(c))
          .toList();

  /// זיכרון לכל חיפוש: בלעדיו כל שורה סורקת שוב את כל תת-העץ שלה.
  bool _matches(CatalogCategory category) {
    if (_query.isEmpty) return true;
    final cached = _matchCache[category.id];
    if (cached != null) return cached;
    var result = category.title.contains(_query);
    if (!result) {
      for (final child in widget.catalog.childrenOf[category.id] ??
          const <CatalogCategory>[]) {
        if (_matches(child)) {
          result = true;
          break;
        }
      }
    }
    if (!result) {
      for (final book
          in widget.catalog.booksOf[category.id] ?? const <CatalogBook>[]) {
        if (book.title.contains(_query)) {
          result = true;
          break;
        }
      }
    }
    return _matchCache[category.id] = result;
  }

  /// [filtering] נכבה מתחת לקטגוריה ששמה עצמו תאם: מי שחיפש אותה רוצה
  /// לראות את מה שבתוכה, לא קטגוריה פתוחה וריקה.
  List<Widget> _rows(
    CatalogCategory category,
    int depth, {
    required bool filtering,
  }) {
    final children = _childrenOf(category.id);
    final books = _booksOf(category.id);
    final autoOpen = filtering && _matches(category);
    final open = !_collapsed.contains(category.id) &&
        (_expanded.contains(category.id) || autoOpen);
    final filterBelow = filtering && !category.title.contains(_query);
    final marks = _derived;
    final state = marks.stateOf(category.id);

    return [
      _CategoryRow(
        key: ValueKey('c${category.id}'),
        category: category,
        depth: depth,
        state: state,
        open: open,
        hasChildren: children.isNotEmpty || books.isNotEmpty,
        bookCount: marks.total[category.id] ?? 0,
        bytes: _sizesKnown ? widget.catalog.bytesUnder(category.id) : null,
        checkboxLabel: widget.checkboxLabel,
        onToggleOpen: () => setState(() {
          if (open) {
            _expanded.remove(category.id);
            if (autoOpen) _collapsed.add(category.id);
          } else {
            _collapsed.remove(category.id);
            _expanded.add(category.id);
          }
        }),
        onToggleChecked: () => _toggleCategory(category, state),
      ),
      if (open) ...[
        for (final child in children)
          if (!filterBelow || _matches(child))
            ..._rows(child, depth + 1, filtering: filterBelow),
        for (final book in books)
          if (!filterBelow || book.title.contains(_query))
            _BookRow(
              key: ValueKey('b${book.id}'),
              book: book,
              depth: depth + 1,
              checked: marks.isMarked(book),
              bytes: _sizesKnown ? widget.catalog.estimatedBytesOf(book) : null,
              checkboxLabel: widget.checkboxLabel,
              onToggle: () => _toggleBook(book),
            ),
      ],
    ];
  }

  // ── שינוי הסימון ──────────────────────────────────────────────────

  void _toggleCategory(CatalogCategory category, TriState state) {
    widget.onChanged(
      toggleCategory(widget.catalog, widget.removal, category.id, state),
    );
  }

  void _toggleBook(CatalogBook book) {
    widget.onChanged(toggleBook(widget.catalog, widget.removal, book));
  }
}

/// מצב הסימון של כל העץ, בחישוב אחד מלמטה למעלה.
class TreeMarks {
  final LibraryCatalog catalog;
  final RemovalSelection removal;

  /// ספרים תחת כל קטגוריה, בכל עומק.
  final Map<int, int> total = {};

  /// מתוכם — כמה מסומנים למחיקה.
  final Map<int, int> marked = {};

  /// קטגוריות שהן עצמן או אחד מאבותיהן סומנו.
  final Set<int> covered = {};

  TreeMarks(this.catalog, this.removal) {
    for (final root in catalog.roots) {
      _walk(root.id, false);
    }
  }

  void _walk(int id, bool coveredAbove) {
    final isCovered = coveredAbove || removal.categoryIds.contains(id);
    if (isCovered) covered.add(id);
    var all = 0;
    var on = 0;
    for (final book in catalog.booksOf[id] ?? const <CatalogBook>[]) {
      all++;
      if (isCovered || removal.bookIds.contains(book.id)) on++;
    }
    for (final child in catalog.childrenOf[id] ?? const <CatalogCategory>[]) {
      _walk(child.id, isCovered);
      all += total[child.id] ?? 0;
      on += marked[child.id] ?? 0;
    }
    total[id] = all;
    marked[id] = on;
  }

  bool isMarked(CatalogBook book) =>
      removal.bookIds.contains(book.id) || covered.contains(book.categoryId);

  /// קטגוריה מכוסה מסומנת גם כשאין בה ספרים — אחרת תת-קטגוריה ריקה
  /// תחת אב מסומן הייתה נראית לא מסומנת.
  TriState stateOf(int id) {
    if (covered.contains(id)) return TriState.all;
    final all = total[id] ?? 0;
    final on = marked[id] ?? 0;
    if (all == 0 || on == 0) return TriState.none;
    return on == all ? TriState.all : TriState.partial;
  }
}

/// הבחירה אחרי לחיצה על קטגוריה שמצבה [state].
///
/// בשני הכיוונים מנקים קודם את כל מה שבתוך הענף: הסימון נשמר מצומצם,
/// ובלעדיו סימון של אב היה משאיר מתחתיו סימונים שסותרים אותו.
RemovalSelection toggleCategory(
  LibraryCatalog catalog,
  RemovalSelection removal,
  int categoryId,
  TriState state,
) {
  final categories = removal.categoryIds.toSet()
    ..removeAll(catalog.descendantsOf(categoryId));
  final books = removal.bookIds.toSet()
    ..removeAll(catalog.booksUnder(categoryId).map((b) => b.id));
  if (state != TriState.all) {
    categories.add(categoryId);
  } else {
    _unmarkCovering(catalog, categoryId, categories, books, expandStart: false);
  }
  return RemovalSelection(categoryIds: categories, bookIds: books);
}

/// הבחירה אחרי לחיצה על ספר.
RemovalSelection toggleBook(
  LibraryCatalog catalog,
  RemovalSelection removal,
  CatalogBook book,
) {
  final categories = removal.categoryIds.toSet();
  final books = removal.bookIds.toSet();
  if (TreeMarks(catalog, removal).isMarked(book)) {
    _unmarkCovering(
      catalog,
      book.categoryId,
      categories,
      books,
      expandStart: true,
    );
    books.remove(book.id);
  } else {
    books.add(book.id);
  }
  return RemovalSelection(categoryIds: categories, bookIds: books);
}

/// מבטל סימון של אב שמכסה את [categoryId], בלי לבטל את אחיו.
///
/// ‏[RemovalSelection] אינו יודע לומר "הענף הזה חוץ מהספר הזה", ולכן
/// הסימון של האב נפרס כלפי מטה לאורך **כל** המסלול — בכל רמה, ולא רק
/// בעליונה: האחים שמחוץ למסלול והספרים הישירים מסומנים לחוד.
/// [expandStart] קובע אם גם [categoryId] עצמה נפרסת — כן כשמוציאים
/// ממנה ספר אחד, לא כשמוציאים אותה כולה.
void _unmarkCovering(
  LibraryCatalog catalog,
  int categoryId,
  Set<int> categories,
  Set<int> books, {
  required bool expandStart,
}) {
  final path = <int>[];
  var current = categoryId;
  final seen = <int>{};
  while (seen.add(current)) {
    path.add(current);
    if (categories.contains(current)) break;
    final parent = catalog.parentOf[current];
    if (parent == null) return;
    current = parent;
  }
  if (!categories.remove(path.last)) return;

  for (var i = path.length - 1; i >= 0; i--) {
    if (i == 0 && !expandStart) break;
    final id = path[i];
    final onPath = i > 0 ? path[i - 1] : null;
    for (final child in catalog.childrenOf[id] ?? const <CatalogCategory>[]) {
      if (child.id != onPath) categories.add(child.id);
    }
    for (final book in catalog.booksOf[id] ?? const <CatalogBook>[]) {
      books.add(book.id);
    }
  }
}

class _CategoryRow extends StatelessWidget {
  final CatalogCategory category;
  final int depth;
  final TriState state;
  final bool open;
  final bool hasChildren;
  final int bookCount;

  /// ‏`null` כשהגדלים אינם ידועים — ואז אין מה להציג.
  final int? bytes;
  final String? checkboxLabel;
  final VoidCallback onToggleOpen;
  final VoidCallback onToggleChecked;

  const _CategoryRow({
    super.key,
    required this.category,
    required this.depth,
    required this.state,
    required this.open,
    required this.hasChildren,
    required this.bookCount,
    required this.bytes,
    required this.checkboxLabel,
    required this.onToggleOpen,
    required this.onToggleChecked,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // גוון עדין לפי מצב הבחירה — כדי שאפשר יהיה לסרוק בעין מה כבר נבחר,
    // בלי לצייר אלפי צללים (אסור בעץ בגודל הזה).
    final tint = switch (state) {
      TriState.all => scheme.primary.withValues(alpha: 0.14),
      TriState.partial => scheme.primary.withValues(alpha: 0.07),
      TriState.none => Colors.transparent,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: tint,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: hasChildren ? onToggleOpen : onToggleChecked,
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(8.0 + depth * 18, 6, 12, 6),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: hasChildren
                      ? Icon(
                          open
                              ? Icons.expand_more_rounded
                              : Icons.chevron_right_rounded,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        )
                      : null,
                ),
                Checkbox(
                  semanticLabel: checkboxLabel,
                  tristate: true,
                  value: switch (state) {
                    TriState.none => false,
                    TriState.partial => null,
                    TriState.all => true,
                  },
                  onChanged: (_) => onToggleChecked(),
                ),
                Expanded(
                  child: Text(
                    category.title,
                    // משקל גבוה יותר מספר — כך שקטגוריה נבדלת בעין בלי
                    // להסתמך רק על ההזחה.
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                if (bytes case final size? when size > 0) ...[
                  _SizeText(bytes: size),
                  const SizedBox(width: 8),
                ],
                if (bookCount > 0)
                  _CountChip(
                    text: formatQuantity(bookCount,
                        one: 'ספר אחד', many: 'ספרים'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// צ'יפ קטן ומעוגל למספר הספרים בקטגוריה.
class _CountChip extends StatelessWidget {
  final String text;

  const _CountChip({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
    );
  }
}

/// גודל משוער בגוון משני — מידע עזר, לא העיקר בשורה.
class _SizeText extends StatelessWidget {
  final int bytes;

  const _SizeText({required this.bytes});

  @override
  Widget build(BuildContext context) => Text(
        '~${formatBytes(bytes)}',
        // ‏"MB" לטיני; בלי כיוון מפורש ה-~ היה נודד לצד הלא נכון ב-RTL.
        textDirection: TextDirection.ltr,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      );
}

class _BookRow extends StatelessWidget {
  final CatalogBook book;
  final int depth;
  final bool checked;
  final int? bytes;
  final String? checkboxLabel;
  final VoidCallback onToggle;

  const _BookRow({
    super.key,
    required this.book,
    required this.depth,
    required this.checked,
    required this.bytes,
    required this.checkboxLabel,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: checked
            ? scheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onToggle,
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(8.0 + depth * 18, 4, 12, 4),
            child: Row(
              children: [
                const SizedBox(width: 24),
                Checkbox(
                  semanticLabel: checkboxLabel,
                  value: checked,
                  onChanged: (_) => onToggle(),
                ),
                Expanded(
                  child: Text(
                    book.title,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                // כשהגודל ידוע הוא מה שמעניין את מי שמפנה מקום; מספר
                // השורות נשאר כתחליף רק כשאין כיול.
                if (bytes case final size?) ...[
                  // ספר בלי שורות אינו תופס מקום; "0 B" רק היה מבלבל.
                  if (size > 0) _SizeText(bytes: size),
                ] else
                  Text(
                    formatQuantity(book.totalLines,
                        one: 'שורה אחת', many: 'שורות'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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

  const CategoryTree({
    super.key,
    required this.catalog,
    required this.removal,
    required this.onChanged,
  });

  @override
  State<CategoryTree> createState() => _CategoryTreeState();
}

class _CategoryTreeState extends State<CategoryTree> {
  final Set<int> _expanded = {};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final roots = _visibleRoots();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: TextField(
            // בלי border מפורש — השדה מקבל את העיצוב הכללי
            // מ-InputDecorationTheme ולא נראה שונה משאר האפליקציה.
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: 'חיפוש ספר או קטגוריה',
              isDense: true,
            ),
            onChanged: (value) => setState(() => _query = value.trim()),
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
                      const Text('אין תוצאות'),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    for (final root in roots) ..._rows(root, 0),
                  ],
                ),
        ),
      ],
    );
  }

  /// בחיפוש מוצגות רק קטגוריות שיש תחתיהן התאמה, והן נפתחות מאליהן —
  /// אחרת המשתמש היה מקבל רשימה סגורה בלי לדעת מה בתוכה.
  List<CatalogCategory> _visibleRoots() =>
      widget.catalog.roots.where((c) => _query.isEmpty || _matches(c)).toList();

  bool _matches(CatalogCategory category) {
    if (_query.isEmpty) return true;
    if (category.title.contains(_query)) return true;
    for (final child in widget.catalog.childrenOf[category.id] ??
        const <CatalogCategory>[]) {
      if (_matches(child)) return true;
    }
    for (final book
        in widget.catalog.booksOf[category.id] ?? const <CatalogBook>[]) {
      if (book.title.contains(_query)) return true;
    }
    return false;
  }

  List<Widget> _rows(CatalogCategory category, int depth) {
    final children =
        widget.catalog.childrenOf[category.id] ?? const <CatalogCategory>[];
    final books = widget.catalog.booksOf[category.id] ?? const <CatalogBook>[];
    final open = _expanded.contains(category.id) ||
        (_query.isNotEmpty && _matches(category));
    final state = _stateOf(category);

    return [
      _CategoryRow(
        category: category,
        depth: depth,
        state: state,
        open: open,
        hasChildren: children.isNotEmpty || books.isNotEmpty,
        bookCount: widget.catalog.booksUnder(category.id).length,
        onToggleOpen: () => setState(() {
          if (!_expanded.remove(category.id)) _expanded.add(category.id);
        }),
        onToggleChecked: () => _toggleCategory(category, state),
      ),
      if (open) ...[
        for (final child in children)
          if (_query.isEmpty || _matches(child)) ..._rows(child, depth + 1),
        for (final book in books)
          if (_query.isEmpty || book.title.contains(_query))
            _BookRow(
              book: book,
              depth: depth + 1,
              checked: _marked(book),
              onToggle: () => _toggleBook(book),
            ),
      ],
    ];
  }

  // ── מצב נגזר ──────────────────────────────────────────────────────

  TriState _stateOf(CatalogCategory category) {
    if (widget.removal.categoryIds.contains(category.id)) return TriState.all;
    final books = widget.catalog.booksUnder(category.id);
    if (books.isEmpty) return TriState.none;
    var marked = 0;
    for (final book in books) {
      if (_marked(book)) marked++;
    }
    if (marked == 0) return TriState.none;
    return marked == books.length ? TriState.all : TriState.partial;
  }

  bool _marked(CatalogBook book) =>
      widget.removal.bookIds.contains(book.id) ||
      _markedAncestor(book.categoryId);

  bool _markedAncestor(int categoryId) {
    var current = categoryId;
    final seen = <int>{};
    while (seen.add(current)) {
      if (widget.removal.categoryIds.contains(current)) return true;
      final parent = widget.catalog.parentOf[current];
      if (parent == null) return false;
      current = parent;
    }
    return false;
  }

  // ── שינוי הסימון ──────────────────────────────────────────────────

  void _toggleCategory(CatalogCategory category, TriState state) {
    final categories = widget.removal.categoryIds.toSet();
    final books = widget.removal.bookIds.toSet();
    final descendants = widget.catalog.descendantsOf(category.id);
    final bookIds =
        widget.catalog.booksUnder(category.id).map((b) => b.id).toSet();

    // בשני הכיוונים מנקים קודם את כל מה שבתוך הענף: הסימון נשמר מצומצם,
    // ובלעדיו סימון של אב היה משאיר מתחתיו סימונים שסותרים אותו.
    categories.removeAll(descendants);
    books.removeAll(bookIds);
    if (state != TriState.all) {
      categories.add(category.id);
    } else {
      _unmarkAncestorsOf(category.id, categories, books);
    }

    widget.onChanged(
      RemovalSelection(categoryIds: categories, bookIds: books),
    );
  }

  void _toggleBook(CatalogBook book) {
    final categories = widget.removal.categoryIds.toSet();
    final books = widget.removal.bookIds.toSet();

    if (_marked(book)) {
      _unmarkAncestorsOf(book.categoryId, categories, books);
      books.remove(book.id);
    } else {
      books.add(book.id);
    }

    widget.onChanged(
      RemovalSelection(categoryIds: categories, bookIds: books),
    );
  }

  /// מבטל סימון של אב שמכסה את [categoryId], בלי לבטל את אחיו.
  ///
  /// ‏[RemovalSelection] אינו יודע לומר "הענף הזה חוץ מהספר הזה", ולכן
  /// הסימון של האב נפרס כלפי מטה: ילדיו מסומנים כל אחד לחוד, וכך אפשר
  /// להוציא צומת אחד מבלי להחזיר את כל הענף.
  void _unmarkAncestorsOf(
    int categoryId,
    Set<int> categories,
    Set<int> books,
  ) {
    final path = <int>[];
    var current = categoryId;
    final seen = <int>{};
    while (seen.add(current)) {
      path.add(current);
      if (categories.contains(current)) break;
      final parent = widget.catalog.parentOf[current];
      if (parent == null) return;
      current = parent;
    }
    if (path.isEmpty || !categories.contains(path.last)) return;

    for (var i = path.length - 1; i >= 0; i--) {
      final id = path[i];
      if (!categories.remove(id)) continue;
      // האח שאינו על המסלול נשאר מסומן, ולכן הוא עובר לסימון משלו.
      for (final child
          in widget.catalog.childrenOf[id] ?? const <CatalogCategory>[]) {
        if (child.id != (i > 0 ? path[i - 1] : -1)) categories.add(child.id);
      }
      for (final book in widget.catalog.booksOf[id] ?? const <CatalogBook>[]) {
        books.add(book.id);
      }
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
  final VoidCallback onToggleOpen;
  final VoidCallback onToggleChecked;

  const _CategoryRow({
    required this.category,
    required this.depth,
    required this.state,
    required this.open,
    required this.hasChildren,
    required this.bookCount,
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
                if (bookCount > 0)
                  _CountChip(text: '${formatCount(bookCount)} ספרים'),
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

class _BookRow extends StatelessWidget {
  final CatalogBook book;
  final int depth;
  final bool checked;
  final VoidCallback onToggle;

  const _BookRow({
    required this.book,
    required this.depth,
    required this.checked,
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
                Checkbox(value: checked, onChanged: (_) => onToggle()),
                Expanded(
                  child: Text(
                    book.title,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                Text(
                  '${formatCount(book.totalLines)} שורות',
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

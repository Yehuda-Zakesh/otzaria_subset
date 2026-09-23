import 'package:meta/meta.dart';

import '../models/subset_spec.dart';
import 'library_catalog.dart';

/// מה שהמשתמש סימן **להחזרה** — ההפך של `RemovalSelection`.
///
/// הבחירה נעשית מול תצלום הקטלוג **המלא** (ראו `LibraryCatalog.toJson`),
/// לא מול הספרייה הגזומה: שם מה שנמחק פשוט אינו קיים.
@immutable
class RestoreSelection {
  /// קטגוריות להחזרה, על כל מה שתחתיהן — גם מה שייכנס אליהן בעתיד.
  final Set<int> categoryIds;

  /// ספרים בודדים להחזרה.
  final Set<int> bookIds;

  const RestoreSelection({
    this.categoryIds = const {},
    this.bookIds = const {},
  });

  static const RestoreSelection empty = RestoreSelection();

  bool get isEmpty => categoryIds.isEmpty && bookIds.isEmpty;

  RestoreSelection copyWith({Set<int>? categoryIds, Set<int>? bookIds}) =>
      RestoreSelection(
        categoryIds: categoryIds ?? this.categoryIds,
        bookIds: bookIds ?? this.bookIds,
      );
}

/// האם [spec] שומר את [book], לפי העץ של [catalog].
///
/// אותה סמנטיקה של `SubsetResolver.resolveBookIds`: קטגוריה (או אב שלה)
/// בכלל ⊎ ספר מפורש, ואז ההחרגה גוברת. העץ שבזיכרון מחליף את
/// ‏`category_closure`, כי שניהם נגזרים מאותו `category.parentId`.
bool specKeepsBook(LibraryCatalog catalog, SubsetSpec spec, CatalogBook book) {
  if (spec.excludeBookIds.contains(book.id)) return false;
  if (spec.includeBookIds.contains(book.id)) return true;
  return catalog
      .ancestorsAndSelf(book.categoryId)
      .any(spec.categoryIds.contains);
}

/// מזהי הספרים של [catalog] ש-[spec] שומר.
Set<int> keptBookIds(LibraryCatalog catalog, SubsetSpec spec) => {
      for (final b in catalog.books)
        if (specKeepsBook(catalog, spec, b)) b.id,
    };

/// מזהי הספרים של [catalog] ש-[spec] **אינו** שומר — מה שאפשר להחזיר.
Set<int> notKeptBookIds(LibraryCatalog catalog, SubsetSpec spec) => {
      for (final b in catalog.books)
        if (!specKeepsBook(catalog, spec, b)) b.id,
    };

/// תת-קטלוג של מה שאפשר להחזיר: הספרים ש-[spec] אינו שומר, והקטגוריות
/// שבדרך אליהם. מיועד להצגה באותו רכיב עץ של מסך המחיקה.
///
/// הכיול והגרסה עוברים מ-[snapshot], כדי שהגדלים שבעץ יהיו של התצלום
/// המלא.
LibraryCatalog restorableCatalog(LibraryCatalog snapshot, SubsetSpec spec) {
  final books = [
    for (final b in snapshot.books)
      if (!specKeepsBook(snapshot, spec, b)) b,
  ];
  final needed = <int>{
    for (final b in books) ...snapshot.ancestorsAndSelf(b.categoryId),
  };
  return LibraryCatalog(
    [
      for (final c in snapshot.categories)
        if (needed.contains(c.id)) c,
    ],
    books,
    bytesPerLine: snapshot.bytesPerLine,
    dbVersion: snapshot.dbVersion,
  );
}

/// מרחיב את כלל השמירה [current] כך שיכלול גם את מה שב-[restore].
///
/// ## מה נשמר מהכלל הקודם
///
/// הכל. ההחזרה רק **מוסיפה**: ספר שנשמר נשאר, החרגה שלא הוחזרה נשארת,
/// וקטגוריות וספרים שאינם בתצלום (חדשים ממנו) עוברים כמות שהם. ענף
/// שהמשתמש לא נגע בו בהחזרה אינו משנה צורה — כלל קטגוריה נשאר כלל,
/// ורשימת ספרים נשארת רשימה.
///
/// ## ענף שהתמלא הופך לכלל קטגוריה
///
/// כמו ב-`keepSpecFor` (§14 ב-AGENTS.md): ענף שההחזרה נגעה בו ושכל ספריו
/// בתצלום נשמרים עכשיו מתבטא כקטגוריה אחת — הגבוהה ביותר שמתאימה — כדי
/// שספר עתידי בו ייכנס מעצמו. הספרים והקטגוריות שמתחתיו יורדים מהכלל
/// כמיותרים. קטגוריה שסומנה להחזרה נשמרת תמיד כך (או דרך אב שהתמלא).
///
/// ההנחה היא שהעץ של [snapshot] עוד מתאר את אפסטרים; ספר שעבר קטגוריה
/// מאז התצלום נשפט לפי מקומו הישן.
SubsetSpec restoreSpecFor(
  LibraryCatalog snapshot,
  SubsetSpec current,
  RestoreSelection restore,
) {
  if (restore.isEmpty) return current;

  final restoredBooks = <int>{
    ...restore.bookIds,
    for (final c in restore.categoryIds)
      for (final b in snapshot.booksUnder(c)) b.id,
  };
  // קטגוריה שסומנה להחזרה ואינה בתצלום (חדשה ממנו) — אין לה ענף לבדוק,
  // והמשתמש ביקש אותה במפורש.
  final unknownCategories = {
    for (final c in restore.categoryIds)
      if (!snapshot.parentOf.containsKey(c)) c,
  };

  final categories = {...current.categoryIds, ...unknownCategories};
  final excludes = current.excludeBookIds.difference(restoredBooks);
  final includes = {...current.includeBookIds};
  final withRestoredCategories = {...categories, ...restore.categoryIds};
  for (final id in restoredBooks) {
    final book = snapshot.bookById(id);
    final covered = book != null &&
        snapshot
            .ancestorsAndSelf(book.categoryId)
            .any(withRestoredCategories.contains);
    if (!covered) includes.add(id);
  }

  // מה שנשמר אחרי ההחזרה, כולל הקטגוריות שסומנו — בסיס לבדיקת "התמלא".
  final widened = SubsetSpec(
    categoryIds: withRestoredCategories,
    includeBookIds: includes,
    excludeBookIds: excludes,
  );
  final kept = keptBookIds(snapshot, widened);

  // רק ענפים שההחזרה נגעה בהם מועמדים לשינוי צורה.
  final touched = <int>{
    for (final c in restore.categoryIds)
      if (snapshot.parentOf.containsKey(c)) ...snapshot.ancestorsAndSelf(c),
    for (final id in restoredBooks)
      if (snapshot.bookById(id) case final book?)
        ...snapshot.ancestorsAndSelf(book.categoryId),
  };

  final promoted = <int>{};
  void walk(CatalogCategory category) {
    if (!touched.contains(category.id)) return;
    if (snapshot.booksUnder(category.id).every((b) => kept.contains(b.id))) {
      promoted.add(category.id);
      return;
    }
    for (final child
        in snapshot.childrenOf[category.id] ?? const <CatalogCategory>[]) {
      walk(child);
    }
  }

  for (final root in snapshot.roots) {
    walk(root);
  }

  for (final p in promoted) {
    final under = snapshot.descendantsOf(p);
    categories.removeWhere(under.contains);
    includes.removeWhere((id) {
      final book = snapshot.bookById(id);
      return book != null && under.contains(book.categoryId);
    });
    // אב שכבר בכלל מכסה את הענף; כפילות לא הייתה משנה דבר מלבד הרעש.
    final coveredAbove =
        snapshot.ancestorsAndSelf(p).skip(1).any(categories.contains);
    if (!coveredAbove) categories.add(p);
  }

  return SubsetSpec(
    categoryIds: categories,
    includeBookIds: includes,
    excludeBookIds: excludes,
  );
}

/// האם בחירה מיובאת [imported] רק **מצמצמת** את [current] — כלומר כל
/// ספר שהיא שומרת כבר על הדיסק, ומספיקה גזימה בלי הורדה.
///
/// ההשוואה רק מול [snapshot], הקטלוג המלא: בקטלוג של ספרייה גזומה ספר
/// חסר אינו מופיע בשני הצדדים, וכל ייבוא היה נראה מצמצם. בלי תצלום, או
/// עם מזהה שאינו בו (נוסף אחריו), אי אפשר לדעת — והתשובה `false`, כלומר
/// בנייה ממסד מלא. ספרייה שעוד לא נגזמה ([hasSubset] שקרי) מלאה, ולכן
/// כל בחירה מצמצמת.
bool importNarrowsOnly({
  required bool hasSubset,
  required LibraryCatalog? snapshot,
  required SubsetSpec current,
  required SubsetSpec imported,
}) {
  if (!hasSubset) return true;
  if (snapshot == null) return false;
  final known = {for (final c in snapshot.categories) c.id};
  if (!known.containsAll(imported.categoryIds)) return false;
  if (!imported.includeBookIds.every((id) => snapshot.bookById(id) != null)) {
    return false;
  }
  return keptBookIds(snapshot, current)
      .containsAll(keptBookIds(snapshot, imported));
}

import 'package:meta/meta.dart';

import '../models/subset_spec.dart';
import 'library_catalog.dart';

/// מה שהמשתמש סימן **למחיקה**.
///
/// ## למה יש כאן שתי שפות
///
/// המשתמש חושב "להוריד את מה שאני לא צריך" — הוא פותח תוכנה עם ספרייה
/// מלאה ומסמן מה למחוק. המנוע חושב הפוך: [SubsetSpec] הוא **כלל של מה
/// נשאר**, וזה מה שמבחן השקילות מוכיח ומה שהסינון של כל patch מסתמך
/// עליו. התרגום בין שתי השפות יושב כאן, במקום אחד, כדי שלא ייסחף.
@immutable
class RemovalSelection {
  /// קטגוריות שסומנו למחיקה, על כל מה שתחתיהן.
  final Set<int> categoryIds;

  /// ספרים בודדים שסומנו למחיקה.
  final Set<int> bookIds;

  const RemovalSelection({
    this.categoryIds = const {},
    this.bookIds = const {},
  });

  static const RemovalSelection empty = RemovalSelection();

  bool get isEmpty => categoryIds.isEmpty && bookIds.isEmpty;

  RemovalSelection copyWith({Set<int>? categoryIds, Set<int>? bookIds}) =>
      RemovalSelection(
        categoryIds: categoryIds ?? this.categoryIds,
        bookIds: bookIds ?? this.bookIds,
      );
}

/// הופך סימון-למחיקה לכלל-שמירה.
///
/// ## למה לא "כל הספרים חוץ מאלה"
///
/// רשימת מזהים של כל מה שנשאר הייתה **תצלום**: ספר שאוצריא תוסיף מחר
/// לקטגוריה שהמשתמש לא נגע בה לא היה נכנס אליה לעולם. לכן התוצאה היא
/// כלל: ענף שלם שלא סומן נשמר כקטגוריה אחת, וכך כל מה שייכנס אליו
/// בעתיד ייכנס מעצמו. ענף שסומן פשוט אינו בכלל — וגם ספר חדש שייכנס
/// אליו לא ייכנס לספרייה, וזו בדיוק כוונת המשתמש.
SubsetSpec keepSpecFor(
  LibraryCatalog catalog,
  RemovalSelection removal,
) {
  final keepCategories = <int>{};
  final keepBooks = <int>{};
  final excludeBooks = <int>{};

  void walk(CatalogCategory category) {
    if (removal.categoryIds.contains(category.id)) return;

    final subtreeBooks = catalog.booksUnder(category.id);
    final touched = subtreeBooks.any((b) => removal.bookIds.contains(b.id)) ||
        catalog.descendantsOf(category.id).any(removal.categoryIds.contains);

    if (!touched) {
      // ענף שלם שלא נגעו בו — קטגוריה אחת מכסה אותו, כולל מה שייכנס
      // אליו בעתיד.
      keepCategories.add(category.id);
      return;
    }

    // ענף מעורב: הספרים הישירים נשמרים אחד-אחד, והילדים נבדקים לחוד.
    for (final book in catalog.booksOf[category.id] ?? const <CatalogBook>[]) {
      if (!removal.bookIds.contains(book.id)) keepBooks.add(book.id);
    }
    for (final child
        in catalog.childrenOf[category.id] ?? const <CatalogCategory>[]) {
      walk(child);
    }
  }

  for (final root in catalog.roots) {
    walk(root);
  }

  // ספר שסומן למחיקה בתוך ענף שנשמר שלם חייב חריגה מפורשת, אחרת
  // הקטגוריה שמעליו הייתה מחזירה אותו.
  for (final bookId in removal.bookIds) {
    if (!keepBooks.contains(bookId)) excludeBooks.add(bookId);
  }

  return SubsetSpec(
    categoryIds: keepCategories,
    includeBookIds: keepBooks,
    excludeBookIds: excludeBooks,
  );
}

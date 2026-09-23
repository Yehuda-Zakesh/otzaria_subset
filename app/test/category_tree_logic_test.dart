import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:otzaria_subset_app/widgets/category_tree.dart';
import 'package:otzaria_subset_app/widgets/format.dart';

// עץ סינתטי: A(1) ← X(2) ← {C(3), D(4)}; E(5) ריקה תחת A.
// ספרים: a1 ב-A, x1 ב-X, c1 ב-C, d1 ב-D.
CatalogCategory _cat(int id, int? parent) => CatalogCategory(
      id: id,
      parentId: parent,
      title: 'c$id',
      level: 0,
      orderIndex: id,
    );

CatalogBook _book(int id, int category) =>
    CatalogBook(id: id, categoryId: category, title: 'b$id', totalLines: 1);

final _catalog = LibraryCatalog(
  [_cat(1, null), _cat(2, 1), _cat(3, 2), _cat(4, 2), _cat(5, 1)],
  [_book(10, 1), _book(20, 2), _book(30, 3), _book(40, 4)],
);

void main() {
  group('toggleBook', () {
    test('הוצאת ספר עמוק מענף מסומן משאירה את כל השאר מסומן', () {
      const removal = RemovalSelection(categoryIds: {1});
      final next = toggleBook(_catalog, removal, _book(30, 3));
      final marks = TreeMarks(_catalog, next);
      // כל ספר חוץ מ-c1 עדיין מסומן — כולל x1 ו-d1 שברמת הביניים.
      expect(marks.isMarked(_book(10, 1)), isTrue);
      expect(marks.isMarked(_book(20, 2)), isTrue);
      expect(marks.isMarked(_book(40, 4)), isTrue);
      expect(marks.isMarked(_book(30, 3)), isFalse);
      // הקטגוריות שלא נגעו בהן נשארות כלל קטגוריה, לא רשימת ספרים.
      expect(next.categoryIds, containsAll(<int>{4, 5}));
      expect(marks.stateOf(1), TriState.partial);
    });

    test('הוצאת ספר מקטגוריה שסומנה ישירות', () {
      const removal = RemovalSelection(categoryIds: {2});
      final next = toggleBook(_catalog, removal, _book(20, 2));
      expect(next.categoryIds, {3, 4});
      expect(next.bookIds, isEmpty);
    });
  });

  group('toggleCategory', () {
    test('ביטול תת-קטגוריה תחת אב מסומן אינו מבטל את אחיותיה', () {
      const removal = RemovalSelection(categoryIds: {1});
      final next = toggleCategory(_catalog, removal, 3, TriState.all);
      final marks = TreeMarks(_catalog, next);
      expect(marks.isMarked(_book(30, 3)), isFalse);
      expect(marks.isMarked(_book(40, 4)), isTrue);
      expect(marks.isMarked(_book(20, 2)), isTrue);
      expect(marks.isMarked(_book(10, 1)), isTrue);
      expect(next.categoryIds.contains(3), isFalse);
    });

    test('סימון אב מעורב מסמן הכול ומצמצם את הבחירה', () {
      const removal = RemovalSelection(bookIds: {30});
      final next = toggleCategory(_catalog, removal, 1, TriState.partial);
      expect(next.categoryIds, {1});
      expect(next.bookIds, isEmpty);
    });

    test('קטגוריה ריקה תחת אב מסומן מוצגת מסומנת', () {
      const removal = RemovalSelection(categoryIds: {1});
      expect(TreeMarks(_catalog, removal).stateOf(5), TriState.all);
    });

    test('keepSpecFor אחרי ביטול עמוק שומר רק את מה שבוטל', () {
      const removal = RemovalSelection(categoryIds: {1});
      final next = toggleCategory(_catalog, removal, 3, TriState.all);
      final spec = keepSpecFor(_catalog, next);
      expect(spec.categoryIds, {3});
      expect(spec.includeBookIds, isEmpty);
    });
  });

  group('format', () {
    test('formatBytes', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(-2048), '-2.0 KB');
      expect(formatBytes(1024 * 1024 - 1), '1.0 MB');
      expect(formatBytes(1 << 30), '1.0 GB');
    });

    test('formatQuantity', () {
      expect(formatQuantity(1, one: 'ספר אחד', many: 'ספרים'), 'ספר אחד');
      expect(
          formatQuantity(1200, one: 'ספר אחד', many: 'ספרים'), '1,200 ספרים');
    });

    test('hasInternalTerms', () {
      expect(hasInternalTerms('מעתיק line — 5 שורות'), isTrue);
      expect(hasInternalTerms('בונה ספרייה חלקית…'), isTrue);
      expect(hasInternalTerms('צריך בערך 3.2GB פנויים'), isFalse);
      expect(hasInternalTerms('בונה אינדקס 2 מתוך 9'), isFalse);
    });
  });
}

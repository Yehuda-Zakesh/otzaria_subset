import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:otzaria_subset_app/widgets/category_tree.dart';
import 'package:otzaria_subset_app/widgets/format.dart';

import 'widget_harness.dart';

// עץ סינתטי: שורש אחד עם שתי תת-קטגוריות — הקטנה ראשונה בסדר הספרייה,
// כדי שמיון לפי גודל יהפוך את הסדר ויהיה אפשר לראות שהוא פעל.
CatalogCategory _cat(int id, int? parent, String title) => CatalogCategory(
      id: id,
      parentId: parent,
      title: title,
      level: 0,
      orderIndex: id,
    );

LibraryCatalog _catalog({double bytesPerLine = 100}) => LibraryCatalog(
      [
        _cat(1, null, 'שורש'),
        _cat(2, 1, 'ענף קטן'),
        _cat(3, 1, 'ענף גדול'),
      ],
      const [
        // שמות בסדר אלפביתי הפוך לגודל, מאותה סיבה.
        CatalogBook(id: 10, categoryId: 1, title: 'ספר א', totalLines: 10),
        CatalogBook(id: 11, categoryId: 1, title: 'ספר ב', totalLines: 5000),
        CatalogBook(id: 20, categoryId: 2, title: 'ספר ג', totalLines: 20),
        CatalogBook(id: 30, categoryId: 3, title: 'ספר ד', totalLines: 900),
      ],
      bytesPerLine: bytesPerLine,
    );

Future<void> _pumpTree(WidgetTester tester, LibraryCatalog catalog) =>
    pumpInApp(
      tester,
      CategoryTree(
        catalog: catalog,
        removal: const RemovalSelection(),
        onChanged: (_) {},
      ),
    );

String _size(int bytes) => '~${formatBytes(bytes)}';

double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

void main() {
  testWidgets('גדלים מוצגים לקטגוריה ולספר כשהכיול ידוע', (tester) async {
    final catalog = _catalog();
    await _pumpTree(tester, catalog);
    expect(find.text(_size(catalog.bytesUnder(1))), findsOneWidget);

    await tester.tap(find.text('שורש'));
    await tester.pumpAndSettle();
    expect(find.text(_size(catalog.bytesUnder(3))), findsOneWidget);
    final big = catalog.bookById(11)!;
    expect(find.text(_size(catalog.estimatedBytesOf(big))), findsOneWidget);
    expect(find.byKey(const ValueKey('sort-by-size')), findsOneWidget);
    expectNoInternalTerms(tester);
  });

  testWidgets('בלי כיול אין גדלים ואין כפתור מיון', (tester) async {
    await _pumpTree(tester, _catalog(bytesPerLine: 0));
    await tester.tap(find.text('שורש'));
    await tester.pumpAndSettle();

    expect(find.textContaining('~'), findsNothing);
    expect(find.textContaining(' B'), findsNothing);
    expect(find.byKey(const ValueKey('sort-by-size')), findsNothing);
    // מספר השורות נשאר כתחליף.
    expect(find.text('5,000 שורות'), findsOneWidget);
  });

  testWidgets('מיון לפי גודל מציג את הגדול ראשון, ובחזרה', (tester) async {
    await _pumpTree(tester, _catalog());
    await tester.tap(find.text('שורש'));
    await tester.pumpAndSettle();

    // סדר הספרייה: הקטן ראשון, והספרים לפי שם.
    expect(_top(tester, 'ענף קטן'), lessThan(_top(tester, 'ענף גדול')));
    expect(_top(tester, 'ספר א'), lessThan(_top(tester, 'ספר ב')));

    await tester.tap(find.byKey(const ValueKey('sort-by-size')));
    await tester.pumpAndSettle();
    expect(_top(tester, 'ענף גדול'), lessThan(_top(tester, 'ענף קטן')));
    expect(_top(tester, 'ספר ב'), lessThan(_top(tester, 'ספר א')));

    await tester.tap(find.byKey(const ValueKey('sort-by-size')));
    await tester.pumpAndSettle();
    expect(_top(tester, 'ענף קטן'), lessThan(_top(tester, 'ענף גדול')));
  });

  testWidgets('החיפוש ממשיך לעבוד יחד עם המיון', (tester) async {
    await _pumpTree(tester, _catalog());
    await tester.tap(find.byKey(const ValueKey('sort-by-size')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ספר');
    await tester.pumpAndSettle();

    // כל הענפים נפתחים מאליהם בחיפוש, והסדר עדיין לפי גודל.
    expect(_top(tester, 'ענף גדול'), lessThan(_top(tester, 'ענף קטן')));
    expect(_top(tester, 'ספר ב'), lessThan(_top(tester, 'ספר א')));
    expect(find.text('ספר ג'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ספר ד');
    await tester.pumpAndSettle();
    // בתוך הרשימה בלבד — גם שדה החיפוש עצמו מכיל עכשיו את הטקסט.
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('ספר ד'),
      ),
      findsOneWidget,
    );
    expect(find.text('ספר ב'), findsNothing);
    expect(find.text('ענף קטן'), findsNothing);
  });
}

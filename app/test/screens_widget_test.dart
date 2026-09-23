import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:otzaria_subset_app/main.dart';
import 'package:otzaria_subset_app/screens/book_selection_screen.dart';
import 'package:otzaria_subset_app/screens/home_screen.dart';
import 'package:otzaria_subset_app/screens/restore_screen.dart';
import 'package:otzaria_subset_app/services/otzaria_install.dart';
import 'package:otzaria_subset_app/state/app_settings.dart';
import 'package:path/path.dart' as p;

import 'widget_harness.dart';

/// בדיקות עשן למסכים: מצב מתוך תיקייה זמנית, בלי רשת ובלי מסד אמיתי.
void main() {
  late Directory dir;
  late AppState state;

  // תצלום: 1 → 10 (ספרים 1,2), 2 → 20 (ספר 3).
  final snapshot = LibraryCatalog(
    const [
      CatalogCategory(
          id: 1, parentId: null, title: 'ענף א', level: 0, orderIndex: 1),
      CatalogCategory(
          id: 10, parentId: 1, title: 'ענף ב', level: 1, orderIndex: 1),
      CatalogCategory(
          id: 2, parentId: null, title: 'ענף ג', level: 0, orderIndex: 2),
      CatalogCategory(
          id: 20, parentId: 2, title: 'ענף ד', level: 1, orderIndex: 1),
    ],
    const [
      CatalogBook(id: 1, categoryId: 10, title: 'ספר 1', totalLines: 10),
      CatalogBook(id: 2, categoryId: 10, title: 'ספר 2', totalLines: 10),
      CatalogBook(id: 3, categoryId: 20, title: 'ספר 3', totalLines: 10),
    ],
    bytesPerLine: 10,
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('screens_widget_test');
    state = AppState(AppSettingsStore.at(dir.path));
  });

  tearDown(() {
    state.dispose();
    dir.deleteSync(recursive: true);
  });

  void pruned({SubsetSpec spec = const SubsetSpec(categoryIds: {1})}) =>
      state.saveProfile(SubsetProfile(
        id: 'pc',
        label: 'PC',
        spec: spec,
        categoriesPruned: true,
      ));

  Future<void> pump(WidgetTester tester, Widget screen) =>
      pumpInApp(tester, AppScope(state: state, child: screen));

  group('RestoreScreen', () {
    Future<List<SubsetSpec>> pumpRestore(
      WidgetTester tester, {
      List<int>? fetched,
    }) async {
      final restored = <SubsetSpec>[];
      await pump(
        tester,
        RestoreScreen(
          onRestore: restored.add,
          onFetchFull: () => fetched?.add(1),
        ),
      );
      await tester.pumpAndSettle();
      return restored;
    }

    testWidgets('ספרייה שלא נגזמה: אין מה להחזיר', (tester) async {
      await pumpRestore(tester);
      expect(find.textContaining('עוד לא נמחקו ספרים'), findsOneWidget);
      expectNoInternalTerms(tester);
    });

    testWidgets('בלי תצלום: מציע הורדה מלאה', (tester) async {
      pruned();
      final fetched = <int>[];
      await pumpRestore(tester, fetched: fetched);
      expect(find.textContaining('אינה שמורה'), findsOneWidget);
      await tester.tap(find.text('הורדת הספרייה המלאה'));
      expect(fetched, [1]);
      expectNoInternalTerms(tester);
    });

    testWidgets('הכל בספרייה: אין מה להחזיר', (tester) async {
      pruned(spec: const SubsetSpec(categoryIds: {1, 2}));
      state.saveCatalogSnapshot(snapshot);
      await pumpRestore(tester);
      expect(find.textContaining('כל הספרים נמצאים'), findsOneWidget);
      expectNoInternalTerms(tester);
    });

    testWidgets('סימון והחזרה: הכלל החדש שומר גם את המוחזר', (tester) async {
      pruned();
      state.saveCatalogSnapshot(snapshot);
      final restored = await pumpRestore(tester);

      // לפני סימון הכפתור כבוי.
      await tester.tap(find.text('החזרת המסומנים'));
      expect(restored, isEmpty);

      await tester.tap(find
          .descendant(
            of: find.byKey(const ValueKey('c2')),
            matching: find.byType(Checkbox),
          )
          .first);
      await tester.pumpAndSettle();
      expect(find.text('ספר אחד יחזור'), findsOneWidget);
      expectNoInternalTerms(tester);

      await tester.tap(find.text('החזרת המסומנים'));
      expect(restored, hasLength(1));
      expect(keptBookIds(snapshot, restored.single), {1, 2, 3});
    });
  });

  testWidgets('HomeScreen: "להביא עכשיו" מפעיל את הבאת הממתינים',
      (tester) async {
    state.debugSetInstall(
      OtzariaInstall(libraryDbPath: p.join(dir.path, 'seforim.db')),
    );
    state.saveProfile(const SubsetProfile(
      id: 'pc',
      label: 'PC',
      spec: SubsetSpec(categoryIds: {1}),
      categoriesPruned: true,
      pendingBookIds: {2},
    ));
    var fetched = 0;
    await pump(
      tester,
      HomeScreen(
        onChooseBooks: () {},
        onCheckUpdates: () {},
        onInstallAppUpdate: () {},
        onFetchPending: () => fetched++,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('ספר אחד שביקשת'), findsOneWidget);
    await tester.tap(find.text('להביא עכשיו'));
    expect(fetched, 1);
    expectNoInternalTerms(tester);
  });

  testWidgets('BookSelectionScreen: כפתורי ייבוא ושמירה', (tester) async {
    state.debugSetInstall(
      OtzariaInstall(libraryDbPath: p.join(dir.path, 'seforim.db')),
    );
    // הקטלוג מוכן מראש — אחרת המסך היה קורא אותו מהמסד ב-Isolate.
    state.setCatalog(snapshot);
    await pump(
      tester,
      BookSelectionScreen(onApply: (_, __) {}, onImport: (_) {}),
    );
    await tester.pumpAndSettle();
    expect(find.text('ייבוא בחירה'), findsOneWidget);
    expect(find.text('שמירת הבחירה לקובץ'), findsOneWidget);

    // לפני גזימה ובלי סימון אין מה לשמור.
    TextButton button(String label) => tester.widget<TextButton>(
          find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is TextButton),
          ),
        );
    expect(button('שמירת הבחירה לקובץ').onPressed, isNull);
    expect(button('ייבוא בחירה').onPressed, isNotNull);

    pruned();
    await tester.pumpAndSettle();
    expect(button('שמירת הבחירה לקובץ').onPressed, isNotNull);
    expectNoInternalTerms(tester);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:otzaria_subset_app/services/error_report.dart';
import 'package:otzaria_subset_app/state/app_settings.dart';
import 'package:otzaria_subset_app/state/app_state.dart';
import 'package:path/path.dart' as p;

/// ‏AppState מול תיקייה זמנית — בלי אוצריא אמיתית ובלי מסד.
void main() {
  late Directory dir;
  late AppState state;

  // תצלום: 1 → 10 (ספרים 1,2), 2 → 20 (ספר 3).
  final snapshot = LibraryCatalog(
    const [
      CatalogCategory(
          id: 1, parentId: null, title: 'א', level: 0, orderIndex: 1),
      CatalogCategory(id: 10, parentId: 1, title: 'ב', level: 1, orderIndex: 1),
      CatalogCategory(
          id: 2, parentId: null, title: 'ג', level: 0, orderIndex: 2),
      CatalogCategory(id: 20, parentId: 2, title: 'ד', level: 1, orderIndex: 1),
    ],
    const [
      CatalogBook(id: 1, categoryId: 10, title: 'ספר 1', totalLines: 1),
      CatalogBook(id: 2, categoryId: 10, title: 'ספר 2', totalLines: 1),
      CatalogBook(id: 3, categoryId: 20, title: 'ספר 3', totalLines: 1),
    ],
    bytesPerLine: 10,
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('app_state_test');
    state = AppState(AppSettingsStore.at(dir.path));
  });

  tearDown(() {
    state.dispose();
    dir.deleteSync(recursive: true);
  });

  group('pendingAcquisition', () {
    test('ממתין שהבחירה כבר אינה שומרת יורד; ממתין שאינו בתצלום נשאר', () {
      state.saveProfile(const SubsetProfile(
        id: 'pc',
        label: 'PC',
        spec: SubsetSpec(categoryIds: {1}),
        // 2 נשמר, 3 בענף שנמחק, 99 חדש מהתצלום.
        pendingBookIds: {2, 3, 99},
      ));
      state.saveCatalogSnapshot(snapshot);
      expect(state.pendingAcquisition, {2, 99});
    });

    test('בלי תצלום אין לפי מה לסנן — הכל נשאר', () {
      state.saveProfile(const SubsetProfile(
        id: 'pc',
        label: 'PC',
        spec: SubsetSpec(categoryIds: {1}),
        pendingBookIds: {2, 3},
      ));
      expect(state.pendingAcquisition, {2, 3});
    });
  });

  test('saveCatalogSnapshot בולע כשל שמירה ורושם ליומן', () {
    state.saveProfile(const SubsetProfile(id: 'pc', label: 'PC'));
    // תיקייה במקום הקובץ: ההחלפה האטומית נכשלת.
    Directory(p.join(state.settingsStore.profilesDir.path, 'pc.catalog'))
        .createSync(recursive: true);
    final before = ErrorLog.instance.entries.length;

    expect(() => state.saveCatalogSnapshot(snapshot), returnsNormally);
    expect(ErrorLog.instance.entries.length, greaterThan(before));
    expect(ErrorLog.instance.entries.last, contains('שמירת רשימת הספרים'));
    expect(state.catalogSnapshot, isNull);
  });
}

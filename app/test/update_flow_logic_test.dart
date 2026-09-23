import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:otzaria_subset_app/services/update_flow.dart';
import 'package:seforim_library_updater/seforim_library_updater.dart';

/// ההחלטות הטהורות של `SubsetUpdateFlow`, בלי רשת ובלי מסד.
void main() {
  const asset = ReleaseAsset(
    name: 'seforim.db.zst',
    downloadUrl: 'https://x/seforim.db.zst',
    size: 1,
  );

  LibraryUpdatePlan full(int? target, {int? followUp}) =>
      LibraryUpdatePlan.fullDownload(
        localVersion: 0,
        targetVersion: target,
        asset: asset,
        releaseTag: 'v$target',
        followUpDelta: followUp == null
            ? null
            : LibraryUpdatePlan.delta(
                localVersion: target ?? 0,
                targetVersion: followUp,
                steps: const [],
              ),
      );

  LocalDbVersion local(int version, {bool meta = true}) => LocalDbVersion(
        dbVersion: version,
        schemaVersion: 2,
        hasVersionMeta: meta,
      );

  // החזרת ספרים מורידה מסד מלא בכפייה. מסד ישן מזה שכאן היה מחזיר את כל
  // התוכן אחורה בשקט — `check(forceFull: true)` חייב לחסום.
  group('forcedFullRegresses', () {
    test('מסד מלא ישן יותר, בלי השלמה: חוסם', () {
      expect(forcedFullRegresses(full(5), local(7)), isTrue);
    });

    test('ההשלמה ב-patches מגיעה לגרסה המקומית ומעבר לה: מותר', () {
      expect(forcedFullRegresses(full(5, followUp: 7), local(7)), isFalse);
      expect(forcedFullRegresses(full(5, followUp: 9), local(7)), isFalse);
    });

    test('ההשלמה עצמה נעצרת לפני הגרסה המקומית: חוסם', () {
      expect(forcedFullRegresses(full(3, followUp: 5), local(7)), isTrue);
    });

    test('אותה גרסה או חדשה ממנה: מותר', () {
      expect(forcedFullRegresses(full(7), local(7)), isFalse);
      expect(forcedFullRegresses(full(8), local(7)), isFalse);
    });

    test('יעד לא ידוע מול גרסה מקומית ידועה: חוסם', () {
      expect(forcedFullRegresses(full(null), local(7)), isTrue);
    });

    test('גרסה מקומית לא ידועה אינה חוסמת', () {
      expect(forcedFullRegresses(full(1), local(0, meta: false)), isFalse);
    });

    test('רק תוכנית של הורדה מלאה נבדקת', () {
      final none = LibraryUpdatePlan.none(localVersion: 7, targetVersion: 3);
      expect(forcedFullRegresses(none, local(7)), isFalse);
    });
  });

  // גזימה בבנייה מחדש כשהמקור הוא הספרייה עצמה: ספר שהמתין לא הגיע, ואסור
  // שהרשימה תתאפס — אחרת "להביא עכשיו" נעלם והספר נשכח.
  group('profileAfterInPlaceRebuild', () {
    const profile = SubsetProfile(
      id: 'pc',
      label: 'PC',
      spec: SubsetSpec(categoryIds: {1, 2}),
      pendingBookIds: {5, 7},
    );
    SubsetRebuildResult rebuilt(Set<int> books) => SubsetRebuildResult(
          dbVersion: 9,
          schemaVersion: 2,
          subsetHash: 'subset:x',
          bookIds: books,
          keepCategories: const {1},
          resultBytes: 100,
          indexInvalidation: null,
        );

    test('ממתינים שלא נבנו נשמרים', () {
      final after = profileAfterInPlaceRebuild(
        profile,
        const SubsetSpec(categoryIds: {1}),
        rebuilt({1, 2}),
      );
      expect(after.pendingBookIds, {5, 7});
      expect(after.spec, const SubsetSpec(categoryIds: {1}));
      expect(after.categoriesPruned, isTrue);
      expect(after.dbVersion, 9);
      expect(after.subsetHash, 'subset:x');
    });

    test('ממתין שנבנה (המקור היה מלא) כבר אינו ממתין', () {
      final after = profileAfterInPlaceRebuild(
        profile,
        const SubsetSpec(categoryIds: {1}),
        rebuilt({1, 7}),
      );
      expect(after.pendingBookIds, {5});
    });
  });
}

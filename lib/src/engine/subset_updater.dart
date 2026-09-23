import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../models/profile.dart';
import '../models/subset_spec.dart';
import 'patch_filter.dart';
import 'subset_hasher.dart';
import 'subset_rebuilder.dart'
    show settleSqliteSidecars, moveSqliteSidecars, deleteSqliteFile;
import 'subset_resolver.dart';

/// נזרק כשעדכון תת-קבוצה נכשל. המסד של המשתמש נשאר כשהיה.
class SubsetUpdateException implements Exception {
  final String message;
  const SubsetUpdateException(this.message);
  @override
  String toString() => 'SubsetUpdateException: $message';
}

/// תוצאת עדכון מוצלח.
class SubsetUpdateResult {
  /// הגרסה שהמסד הגיע אליה.
  final int toVersion;

  /// ה-hash החלקי החדש, לשמירה בפרופיל.
  final String subsetHash;

  /// הבחירה בפועל אחרי העדכון.
  final Set<int> bookIds;

  /// ספרים שהכלל בוחר אך תוכנם לא היה ב-patch — ראו
  /// [PatchKeepResolution.pendingAcquisition]. **צריך להציג למשתמש:**
  /// אלה ספרים שהוא ביקש ולא קיבל, והם יגיעו רק בהבאה ממסד מלא.
  final Set<int> pendingAcquisition;

  /// מה נשמר ומה נפל בסינון.
  final PatchFilterReport filterReport;

  const SubsetUpdateResult({
    required this.toVersion,
    required this.subsetHash,
    required this.bookIds,
    required this.pendingAcquisition,
    required this.filterReport,
  });

  bool get hasPendingAcquisition => pendingAcquisition.isNotEmpty;
}

/// מחיל patch של אוצריא על ספרייה חלקית.
///
/// ## למה העבודה נעשית על העתק
///
/// `PatchApplier` של אפסטרים מאמת את התוצאה **בתוך** ה-transaction מול
/// `toContentHash`, ומגלגל אחורה כשאינו תואם. על מסד חלקי ה-hash הזה לא
/// יתאים לעולם, ולכן האימות שם כבוי — ואיתו נעלם ה-`ROLLBACK` שהוא כל
/// הערך שלו.
///
/// הפתרון כאן הוא לשחזר את אותה בטיחות בשכבה אחת מעל: העדכון רץ על
/// **העתק** של תת-הקבוצה, נבדק אחרי ה-commit, ורק אז מחליף את המקור.
/// תת-קבוצה היא מאות MB ולא 7.4GB, ולכן עותק נוסף הוא מחיר סביר —
/// והחלופה היא מסד שעבר patch שגוי בלי דרך חזרה.
///
/// ## מה האימות כאן כן בודק
///
/// שלמות: `foreign_key_check` ו-`quick_check` על התוצאה, וה-hash החלקי
/// **של הגרסה הקודמת** מול מה שנרשם בפרופיל — כלומר שהמסד לא נגע בו
/// אף אחד בין העדכונים. מה שהוא **אינו** בודק הוא שהמסנן צודק; לזה יש
/// מבחן השקילות ב-`test/equivalence_test.dart`.
///
/// סינכרוני וחוסם — הרץ ב-`Isolate.run`.
class SubsetUpdater {
  final PatchFilter filter;
  final SubsetResolver resolver;
  final SubsetHasher hasher;
  final PatchApplier applier;

  const SubsetUpdater({
    this.filter = const PatchFilter(),
    this.resolver = const SubsetResolver(),
    this.hasher = const SubsetHasher(),
    this.applier = const PatchApplier(),
  });

  /// מחיל [patchPath] על תת-הקבוצה של [profile].
  ///
  /// [workDir] היא תיקיית עבודה לקבצים הזמניים (ה-patch המסונן וההעתק).
  /// היא צריכה לשבת על **אותו כרך** כמו המסד, כדי שההחלפה בסוף תהיה
  /// ‏`rename` אטומי ולא העתקה בין כרכים.
  ///
  /// [expectedHash] — ה-hash החלקי שנרשם בפרופיל. כשהוא מסופק ואינו
  /// תואם, העדכון נעצר: המסד שונה מאז העדכון הקודם, והחלת patch עליו
  /// תייצר תוצאה שאף אחד אינו יכול להסביר.
  ///
  /// [categoriesPruned] — האם המסד הזה נבנה עם עץ קטגוריות גזום. **חייב
  /// לתאר את המסד שעל הדיסק**, ולכן הוא נשמר בפרופיל
  /// (`SubsetProfile.categoriesPruned`) ולא נגזר כאן: אין דרך אמינה
  /// להסתכל על מסד חלקי ולדעת אם עץ הקטגוריות שלו נגזם או שהספרייה
  /// המלאה פשוט לא כללה את הענפים האלה. ערך שגוי כאן מייצר הפרת מפתח
  /// זר — כשל רועש, לא שקט, אבל מיותר.
  SubsetUpdateResult applyPatch({
    required String subsetPath,
    required String patchPath,
    required DeltaManifest manifest,
    required SubsetSpec spec,
    required String workDir,
    required bool categoriesPruned,
    String? expectedHash,
    void Function(String stage)? onStage,
  }) {
    final subset = File(subsetPath);
    if (!subset.existsSync()) {
      throw SubsetUpdateException('הספרייה החלקית אינה קיימת: $subsetPath');
    }
    if (!File(patchPath).existsSync()) {
      throw SubsetUpdateException('קובץ העדכון אינו קיים: $patchPath');
    }
    final work = Directory(workDir);
    if (!work.existsSync()) work.createSync(recursive: true);

    final stamp = DateTime.now().microsecondsSinceEpoch;
    final staged = File(p.join(workDir, 'subset-$stamp.staging.db'));
    final filtered = File(p.join(workDir, 'patch-$stamp.filtered.db'));

    try {
      // ‏WAL חם של המסד אינו נכלל בהעתקה, ואחרי ההחלפה היה מוחל על הקובץ
      // החדש לפי השם. מקפלים אותו לתוך הקובץ לפני שנוגעים בו.
      try {
        settleSqliteSidecars(subsetPath);
      } catch (e) {
        throw SubsetUpdateException('הספרייה החלקית אינה במצב עקבי: $e');
      }

      // ── הגרסה שלפני: תואמת למה שנרשם? ──
      if (expectedHash != null) {
        onStage?.call('verifyLocal');
        final actual = _hashOf(subsetPath, manifest.fromSchemaVersion);
        if (actual != expectedHash) {
          throw const SubsetUpdateException(
            'הספרייה החלקית שונה ממה שנרשם בעדכון הקודם. '
            'העדכון נעצר כדי לא להחיל patch על מסד שאינו במצב הצפוי — '
            'יש לבנות מחדש ממסד מלא.',
          );
        }
      }

      // ── מי בפנים אחרי ה-patch, ומי ממתין להבאה ──
      onStage?.call('resolve');
      final resolution = _resolve(subsetPath, spec, patchPath);

      onStage?.call('filter');
      final report = filter.filter(
        patchPath: patchPath,
        subsetPath: subsetPath,
        outputPath: filtered.path,
        bookIds: resolution.keep,
        keepCategoryIds: categoriesPruned ? resolution.keepCategories : null,
      );

      // ── ההחלה על העתק, לא על המקור ──
      onStage?.call('stage');
      subset.copySync(staged.path);

      onStage?.call('apply');
      applier.apply(
        dbPath: staged.path,
        patchPath: filtered.path,
        manifest: manifest,
        // שני האימותים מול אפסטרים כבויים: ה-hashes שבמניפסט הם של המסד
        // המלא ואינם ברי-השוואה לתת-קבוצה. מה שמחזיר את הבטיחות הוא
        // ה-staging וה-`_verify` שאחריו.
        verifyFromHash: false,
        verifyToHash: false,
      );

      onStage?.call('verify');
      _verify(staged.path);
      final newHash = _hashOf(staged.path, manifest.toSchemaVersion);

      // ── החלפה ──
      onStage?.call('swap');
      _swap(staged, subset);

      return SubsetUpdateResult(
        toVersion: manifest.toVersion,
        subsetHash: newHash,
        bookIds: resolution.keep,
        pendingAcquisition: resolution.pendingAcquisition,
        filterReport: report,
      );
    } finally {
      // כולל קובצי ה-journal/WAL שלהם, שנשארים אחרי כשל באמצע ההחלה.
      for (final f in [staged, filtered]) {
        deleteSqliteFile(f.path);
      }
    }
  }

  /// מעדכן את הפרופיל מתוצאת עדכון. פונקציה טהורה — הקורא שומר.
  SubsetProfile profileAfter(
    SubsetProfile profile,
    SubsetUpdateResult result, {
    required int schemaVersion,
  }) =>
      profile.copyWith(
        dbVersion: result.toVersion,
        schemaVersion: schemaVersion,
        subsetHash: result.subsetHash,
        lastAppliedAt: DateTime.now(),
      );

  PatchKeepResolution _resolve(
      String subsetPath, SubsetSpec spec, String patchPath) {
    // ‏uri: true נדרש כדי ש-`mode=ro` ב-ATTACH של ה-patch ייחשב.
    final db = sqlite3.sqlite3.open(subsetPath, uri: true);
    try {
      return resolver.resolveForPatch(db, spec, patchPath);
    } finally {
      db.close();
    }
  }

  String _hashOf(String path, int schemaVersion) {
    final db = sqlite3.sqlite3.open(path, mode: sqlite3.OpenMode.readOnly);
    try {
      return hasher.compute(db, schemaVersion: schemaVersion);
    } finally {
      db.close();
    }
  }

  void _verify(String path) {
    final db = sqlite3.sqlite3.open(path);
    try {
      db.execute('PRAGMA foreign_keys = ON');
      final violations = db.select('PRAGMA main.foreign_key_check');
      if (violations.isNotEmpty) {
        throw SubsetUpdateException(
          'העדכון יצר ${violations.length} הפרות מפתח זר. '
          'המסד המקורי לא שונה.',
        );
      }
      final check =
          db.select('PRAGMA main.quick_check').first.values.first as String;
      if (check != 'ok') {
        throw SubsetUpdateException('quick_check נכשל אחרי העדכון: $check');
      }
    } finally {
      db.close();
    }
  }

  /// מחליף את המסד בגרסה המעודכנת.
  ///
  /// המסד הישן נשמר כ-`.bak` עד שההחלפה הצליחה. ב-Windows אין דריסה
  /// ב-`rename`, ולכן הסדר הוא: ישן→`.bak`, חדש→מקום, ואז מחיקת ה-`.bak`.
  /// כשל באמצע משאיר את ה-`.bak` על הדיסק, וזה בדיוק מה שמאפשר לשחזר.
  void _swap(File staged, File target) {
    final backup = File('${target.path}.bak');
    try {
      deleteSqliteFile(backup.path, strict: true);
      target.renameSync(backup.path);
      try {
        // קובצי הלוואי זזים עם הקובץ שלהם, אחרת היו מוחלים על החדש.
        moveSqliteSidecars(target.path, backup.path);
        staged.renameSync(target.path);
      } catch (_) {
        // החדש לא נכנס — מחזירים את הישן למקומו. שחזור שנכשל חייב לומר
        // איפה הספרייה נמצאת, אחרת היא יושבת ב-`.bak` בלי שאיש יודע.
        try {
          backup.renameSync(target.path);
          moveSqliteSidecars(backup.path, target.path);
        } catch (restoreError) {
          throw SubsetUpdateException(
            'החלפת המסד נכשלה, וגם השחזור נכשל. המסד הקודם נמצא '
            'ב-${backup.path} ואפשר לשנות את שמו בחזרה ל-${target.path}. '
            'השגיאה: $restoreError',
          );
        }
        rethrow;
      }
    } on SubsetUpdateException {
      rethrow;
    } catch (e) {
      throw SubsetUpdateException('החלפת המסד נכשלה: $e');
    }
    // מכאן ההחלפה **הצליחה** והמסד כבר בגרסה החדשה. כשל במחיקת הגיבוי
    // שהיה נזרק כאן היה משאיר פרופיל בגרסה הישנה מול מסד בגרסה החדשה.
    deleteSqliteFile(backup.path);
  }
}

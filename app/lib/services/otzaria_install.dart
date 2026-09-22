import 'dart:io';

import 'package:hive_ce/hive.dart';
import 'package:library_manager/library_manager.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// ההתקנה של אוצריא במחשב הזה, כפי שאותרה.
class OtzariaInstall {
  /// ה-`seforim.db` שאוצריא משתמשת בו, או `null` כשלא נמצא.
  final String? libraryDbPath;

  /// תיקיית אינדקס החיפוש, לביטול אחרי כל גיזום.
  final String? indexDir;

  const OtzariaInstall({this.libraryDbPath, this.indexDir});

  bool get found => libraryDbPath != null;

  /// תיקיית עבודה **לצד המסד**, כדי שההחלפה בסוף תהיה `rename` אטומי על
  /// אותו כרך ולא העתקה של גיגה-בייטים בין כרכים.
  String? get workDir {
    final db = libraryDbPath;
    return db == null ? null : p.join(p.dirname(db), '.subset-work');
  }
}

/// מאתר את ההתקנה של אוצריא.
///
/// ## למה דרך `library_manager` ולא חיפוש משלנו
///
/// אוצריא שומרת את מיקום הספרייה בקופסת ה-Hive שלה
/// (`key-library-path` + `key-library-folder-name`), ומשתמש שהעביר את
/// הספרייה לכונן אחר עשה זאת שם. חיפוש בתיקיות ברירת המחדל בלבד היה
/// מוצא קובץ אחר — או לא מוצא כלום — בדיוק אצל מי שהכי צריך את התוכנה
/// הזו. `LibraryDbLocator` כבר מכיר גם התקנה ניידת, גם התקנת מנהל
/// וגם את הגיבוי הישן ב-`C:\אוצריא`, וכל אלה נבדקו מול אוצריא עצמה.
class OtzariaInstallLocator {
  const OtzariaInstallLocator();

  /// מפתח ההגדרה של נתיב האינדקס אצל אוצריא.
  static const String keyIndexPath = 'key-index-path';

  Future<OtzariaInstall> locate({String? overridePath}) async {
    final override = overridePath?.trim();
    if (override != null &&
        override.isNotEmpty &&
        File(override).existsSync()) {
      return OtzariaInstall(
        libraryDbPath: override,
        indexDir: _indexFor(override),
      );
    }
    try {
      final support = await getApplicationSupportDirectory();
      final locator = LibraryDbLocator(
        stateStore:
            LibraryStateStore(p.join(support.path, 'library-state.json')),
      );
      final db = await locator.resolveDbPath();
      if (db == null) return const OtzariaInstall();
      return OtzariaInstall(libraryDbPath: db, indexDir: _indexFor(db));
    } catch (_) {
      // איתור שנכשל אינו שגיאה שמפילה את האפליקציה — המשתמש יתבקש
      // להצביע על המסד בעצמו.
      return const OtzariaInstall();
    }
  }

  /// תיקיית האינדקס: אחות של תיקיית הספרים, כפי שאוצריא מחשבת בעצמה.
  String? _indexFor(String dbPath) =>
      OtzariaIndexInvalidator.resolveIndexDir(libraryPath: dbPath);

  /// קורא מהגדרות אוצריא את מצב העדכון האוטומטי.
  ///
  /// ## למה דרך עותק
  ///
  /// פתיחת קופסת ה-Hive במקומה יוצרת קובץ נעילה בתיקייה של אוצריא
  /// ומתנגשת איתה כשהיא פתוחה. העתקה לתיקייה זמנית מבטיחה שהקריאה
  /// לעולם לא נוגעת בהגדרות של המשתמש. זו אותה גישה שבה
  /// `OtzariaSettingsReader` קורא את נתיב הספרייה.
  Future<OtzariaUpdateSettings> readUpdateSettings() async {
    const guard = OtzariaUpdateGuard();
    String? root;
    try {
      final support = await getApplicationSupportDirectory();
      root = await LibraryDbLocator(
        stateStore:
            LibraryStateStore(p.join(support.path, 'library-state.json')),
      ).otzariaSettingsRoot(null);
    } catch (_) {
      root = null;
    }
    if (root == null) return guard.unknown('הגדרות אוצריא');

    final source = p.join(root, '${OtzariaUpdateGuard.settingsBoxName}.hive');
    if (!File(source).existsSync()) return guard.unknown(source);

    return OtzariaSettingsReader.runExclusively(() async {
      Directory? scratch;
      try {
        scratch = await Directory.systemTemp.createTemp('otzaria-guard-');
        // שם ייחודי לכל קריאה: Hive מזהה קופסה פתוחה לפי שם בלבד.
        final boxName = 'guard-${DateTime.now().microsecondsSinceEpoch}';
        await File(source).copy(p.join(scratch.path, '$boxName.hive'));
        Hive.init(scratch.path);
        final box = await Hive.openBox<dynamic>(boxName, path: scratch.path);
        try {
          return guard.fromValues(
            source: source,
            values: {
              for (final key in const [
                OtzariaUpdateGuard.keySoftwareAndBookUpdates,
                OtzariaUpdateGuard.keyAutoSync,
                OtzariaUpdateGuard.keyOfflineMode,
              ])
                key: box.get(key),
            },
          );
        } finally {
          await box.close();
        }
      } catch (_) {
        return guard.unknown(source);
      } finally {
        try {
          await scratch?.delete(recursive: true);
        } catch (_) {}
      }
    });
  }

  /// האם אוצריא רצה כרגע.
  ///
  /// גזימה בזמן שהיא פתוחה פירושה החלפת הקובץ מתחת לרגליה — SQLite פתוח
  /// על קובץ שנעלם, ובמקרה הרע מסד שנשאר עם `-wal` יתום.
  Future<bool> isOtzariaRunning() async {
    try {
      return await const OtzariaProcessGuard().isAnyRunning(
        OtzariaProcessGuard.processNamesFor(Platform.operatingSystem),
      );
    } catch (_) {
      return false;
    }
  }
}

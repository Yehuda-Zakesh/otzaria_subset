import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../engine/library_catalog.dart';
import '../models/profile.dart';

/// נזרק על כתיבה או קריאה שנכשלו.
class ProfileStoreException implements Exception {
  final String message;
  const ProfileStoreException(this.message);
  @override
  String toString() => 'ProfileStoreException: $message';
}

/// מחזיק את הפרופילים כקבצי JSON בתיקייה אחת — בדרך כלל על הכונן הנייד,
/// לצד המראה.
///
/// **כתיבה אטומית, תמיד.** הכונן נשלף מהשקע; כתיבה ישירה לקובץ הפרופיל
/// הייתה משאירה JSON חתוך, וזו רשומה של "מה יש למחשב הזה" — אובדן שלה
/// פירושו בנייה מחדש של ספרייה שלמה. לכן כל שמירה כותבת ל-`.tmp` ואז
/// ‏`rename`, שהוא אטומי באותו כרך.
///
/// הפרופילים נקראים מחדש בכל [loadAll] ואינם נשמרים במטמון: אותו כונן
/// יכול לעבור בין מחשבים, ומטמון בזיכרון היה מחזיר מצב של מחשב אחר.
class ProfileStore {
  /// התיקייה שבה יושבים קובצי הפרופילים.
  final Directory directory;

  ProfileStore(String path) : directory = Directory(path);

  static const String _extension = '.json';

  /// האם הכונן/התיקייה זמינים לכתיבה. קורא לפני שמציעים למשתמש לשמור,
  /// כדי שכונן מוגן-כתיבה ייתן הודעה ולא חריג באמצע.
  bool get isWritable {
    try {
      if (!directory.existsSync()) directory.createSync(recursive: true);
      final probe = File(p.join(directory.path, '.write-probe'));
      probe.writeAsStringSync('');
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// כל הפרופילים, ממוינים לפי שם תצוגה.
  ///
  /// קובץ פגום **אינו** מפיל את הטעינה: הוא מדווח ל-[onCorrupt] ומושמט.
  /// פרופיל אחד שנשבר לא יכול להסתיר את שאר המחשבים שעל הכונן.
  List<SubsetProfile> loadAll({
    void Function(String path, Object error)? onCorrupt,
  }) {
    if (!directory.existsSync()) return const [];
    final profiles = <SubsetProfile>[];
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith(_extension)) continue;
      try {
        final raw = jsonDecode(entity.readAsStringSync());
        if (raw is! Map<String, dynamic>) {
          throw const FormatException('שורש שאינו אובייקט');
        }
        profiles.add(SubsetProfile.fromJson(raw));
      } catch (e) {
        onCorrupt?.call(entity.path, e);
      }
    }
    profiles.sort((a, b) => a.label.compareTo(b.label));
    return profiles;
  }

  /// פרופיל לפי מזהה, או `null`.
  SubsetProfile? load(String id) {
    final file = _fileFor(id);
    if (!file.existsSync()) return _recoverFromTmp(file);
    try {
      return _parse(file);
    } catch (_) {
      return null;
    }
  }

  /// גרסה קודמת מחקה את הקובץ לפני ה-rename, ונפילה ברגע הזה השאירה רק
  /// ‏`.tmp` שלם. בלי שחזור המחשב היה מקבל פרופיל ריק ומאבד את הרשומה.
  SubsetProfile? _recoverFromTmp(File target) {
    final tmp = File('${target.path}.tmp');
    try {
      if (!tmp.existsSync()) return null;
      final profile = _parse(tmp);
      if (profile == null) return null;
      tmp.renameSync(target.path);
      return profile;
    } catch (_) {
      // ‏.tmp חתוך הוא שארית של כתיבה שנכשלה, לא פרופיל.
      return null;
    }
  }

  SubsetProfile? _parse(File file) {
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! Map<String, dynamic>) return null;
    return SubsetProfile.fromJson(raw);
  }

  /// שומר פרופיל אטומית.
  void save(SubsetProfile profile) {
    if (!directory.existsSync()) directory.createSync(recursive: true);
    final target = _fileFor(profile.id);
    final tmp = File('${target.path}.tmp');
    try {
      tmp.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(profile.toJson()),
        flush: true,
      );
      // ‏rename של Dart דורס גם ב-Windows (MOVEFILE_REPLACE_EXISTING).
      // אסור למחוק קודם: rename שנכשל אחרי המחיקה השאיר בלי קובץ ובלי .tmp.
      tmp.renameSync(target.path);
    } catch (e) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      throw ProfileStoreException(
        'שמירת הפרופיל "${profile.label}" נכשלה: $e',
      );
    }
  }

  /// מוחק פרופיל. אינו נוגע ב-`seforim.db` של אותו מחשב — הרשומה נמחקת,
  /// הספרייה עצמה נשארת שם עד שהמשתמש יסיר אותה בעצמו. תצלום הקטלוג של
  /// הפרופיל נמחק איתו: בלי הפרופיל אין לו למי לשייך.
  bool delete(String id) {
    deleteCatalogSnapshot(id);
    final file = _fileFor(id);
    if (!file.existsSync()) return false;
    file.deleteSync();
    return true;
  }

  // ── תצלום הקטלוג המלא ────────────────────────────────────────────

  /// סיומת נפרדת מ-`.json` בכוונה: [loadAll] קורא כל `.json` כפרופיל,
  /// ותצלום שם היה מדווח כפרופיל פגום בכל טעינה.
  static const String _snapshotExtension = '.catalog';

  /// שומר אטומית את קטלוג הספרייה **המלאה** של [profileId] — הבסיס למסך
  /// השחזור. לקרוא לפני הגיזום הראשון (או בכל בנייה ממסד מלא), כשהמסד
  /// עוד שלם; קטלוג של ספרייה גזומה אינו רואה את מה שנמחק.
  void saveCatalogSnapshot(String profileId, LibraryCatalog catalog) {
    if (!directory.existsSync()) directory.createSync(recursive: true);
    final target = _snapshotFor(profileId);
    final tmp = File('${target.path}.tmp');
    try {
      // בלי הזחה: אלפי ספרים, ואף אחד לא קורא את הקובץ בעין.
      tmp.writeAsStringSync(jsonEncode(catalog.toJson()), flush: true);
      tmp.renameSync(target.path);
    } catch (e) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      throw ProfileStoreException('שמירת תצלום הקטלוג נכשלה: $e');
    }
  }

  /// התצלום של [profileId], או `null` אם אין או שהוא פגום. פגום אינו
  /// זורק: בלי תצלום המסך פשוט אינו מציע שחזור.
  LibraryCatalog? loadCatalogSnapshot(String profileId) {
    final file = _snapshotFor(profileId);
    if (!file.existsSync()) return null;
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) return null;
      return LibraryCatalog.fromJson(raw);
    } catch (_) {
      return null;
    }
  }

  /// האם שמור תצלום ל-[profileId], בלי לפענח אותו.
  bool hasCatalogSnapshot(String profileId) =>
      _snapshotFor(profileId).existsSync();

  /// מוחק את התצלום של [profileId]. `false` אם לא היה.
  bool deleteCatalogSnapshot(String profileId) {
    final file = _snapshotFor(profileId);
    if (!file.existsSync()) return false;
    file.deleteSync();
    return true;
  }

  File _snapshotFor(String id) =>
      File(p.join(directory.path, '$id$_snapshotExtension'));

  /// יוצר פרופיל חדש בשם [label], עם מזהה שאינו מתנגש בקיימים.
  SubsetProfile create(String label) {
    final base = SubsetProfile.slugify(label);
    var id = base;
    var n = 2;
    while (_fileFor(id).existsSync()) {
      id = '$base-$n';
      n++;
    }
    final profile = SubsetProfile(id: id, label: label.trim());
    save(profile);
    return profile;
  }

  File _fileFor(String id) => File(p.join(directory.path, '$id$_extension'));
}

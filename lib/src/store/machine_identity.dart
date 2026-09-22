import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// מזהה את המחשב שהתוכנה רצה עליו כרגע.
///
/// המשתמש אינו בוחר מחשב מרשימה — הכונן מגיע למחשב, והתוכנה מזהה לבד
/// לאיזה פרופיל היא שייכת. הבחירה הידנית הייתה נקודת כשל: מי שיבחר את
/// הפרופיל הלא-נכון יקבל patch שמחושב לספרייה אחרת.
///
/// ## למה מזהה מתמיד ולא רק שם המחשב
///
/// שם המחשב משתנה — מישהו משנה אותו, או ששני מחשבים בבית מדרש נקראים
/// אותו דבר. לכן הזהות היא **GUID מתמיד** שנוצר פעם אחת ונשמר
/// **על המחשב** (לא על הכונן): "איזה מחשב זה" הוא תכונה של המחשב.
///
/// שם המחשב נשמר לצדו כרשת ביטחון: אם ה-GUID נמחק (פרמוט, ניקוי
/// ‏`%LOCALAPPDATA%`), ההתאמה נופלת אליו במקום ליצור פרופיל כפול עם
/// ספרייה שכבר קיימת.
class MachineIdentity {
  /// מזהה מתמיד, נוצר פעם אחת לכל מחשב.
  final String id;

  /// שם המחשב ברשת, לתצוגה ולהתאמה חלופית.
  final String hostname;

  /// `windows` / `macos` / `linux`.
  final String platform;

  const MachineIdentity({
    required this.id,
    required this.hostname,
    required this.platform,
  });

  /// שם ברירת המחדל שיוצע למשתמש כשנוצר פרופיל חדש למחשב הזה.
  String get suggestedLabel => hostname.isEmpty ? 'מחשב זה' : hostname;

  /// שם הקובץ שנושא את ה-GUID בתוך תיקיית המצב של המחשב.
  static const String fileName = 'machine-id';

  /// קורא את זהות המחשב, ויוצר אותה בפעם הראשונה.
  ///
  /// [stateDir] הוא מקום **על המחשב** — `%LOCALAPPDATA%` בווינדוס. אין
  /// לשים אותו על הכונן הנייד: הכונן עובר בין מחשבים, וזהות שנשמרת עליו
  /// הייתה מזהה את כולם כאותו מחשב.
  ///
  /// כשלון כתיבה אינו חריג: מוחזרת זהות **חולפת** המבוססת על שם המחשב,
  /// והתאמה תיפול בהמשך על ה-hostname. מחשב נעול לכתיבה עדיין צריך לעבוד.
  static MachineIdentity resolve({String? stateDir}) {
    final host = _hostname();
    final platform = _platformName();
    final dir = stateDir ?? defaultStateDir();

    try {
      final file = File(p.join(dir, fileName));
      if (file.existsSync()) {
        final existing = file.readAsStringSync().trim();
        if (existing.isNotEmpty) {
          return MachineIdentity(
              id: existing, hostname: host, platform: platform);
        }
      }
      final generated = _newGuid();
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(generated, flush: true);
      return MachineIdentity(id: generated, hostname: host, platform: platform);
    } catch (_) {
      // זהות חולפת: יציבה כל עוד שם המחשב יציב.
      return MachineIdentity(
        id: 'host:$host',
        hostname: host,
        platform: platform,
      );
    }
  }

  /// תיקיית המצב המקומית לפי מערכת ההפעלה.
  static String defaultStateDir() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final base = env['LOCALAPPDATA'] ?? env['APPDATA'] ?? '.';
      return p.join(base, 'OtzariaSubset');
    }
    final home = env['HOME'] ?? '.';
    if (Platform.isMacOS) {
      return p.join(home, 'Library', 'Application Support', 'OtzariaSubset');
    }
    return p.join(home, '.local', 'share', 'otzaria-subset');
  }

  static String _hostname() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return '';
    }
  }

  static String _platformName() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return Platform.operatingSystem;
  }

  static String _newGuid() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// קושר מחשבים לפרופילים, בקובץ אחד על הכונן.
///
/// ## למה קובץ נפרד ולא שדה בפרופיל
///
/// "איזה מחשב משתמש בפרופיל הזה" הוא מידע על **הכונן**, לא על הספרייה.
/// הפרדתו לקובץ אחד משאירה את קובצי הפרופילים נקיים וקריאים, ומאפשרת
/// למחשב אחד לשנות שיוך בלי לגעת בקובץ שמתאר ספרייה שלמה.
///
/// הסיומת אינה `.json` **במכוון**: `ProfileStore.loadAll` קורא כל
/// ‏`*.json` בתיקייה, וקובץ רישום שהיה נקרא שם היה מדווח כפרופיל פגום.
class MachineRegistry {
  final File file;

  MachineRegistry(String profilesDir)
      : file = File(p.join(profilesDir, fileName));

  static const String fileName = 'machines.registry';

  /// מזהה הפרופיל המשויך ל-[identity], או `null`.
  ///
  /// סדר ההתאמה: מזהה מתמיד קודם, ושם המחשב רק אחריו. ההיפך היה משייך
  /// שני מחשבים בעלי אותו שם לאותה ספרייה.
  String? profileIdFor(MachineIdentity identity) {
    final map = _read();
    final byId = map[identity.id];
    if (byId is String && byId.isNotEmpty) return byId;

    for (final entry in map.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      if (value['hostname'] == identity.hostname &&
          identity.hostname.isNotEmpty) {
        final id = value['profileId'];
        if (id is String && id.isNotEmpty) return id;
      }
    }
    return null;
  }

  /// משייך [identity] ל-[profileId].
  void bind(MachineIdentity identity, String profileId) {
    final map = _read();
    map[identity.id] = {
      'profileId': profileId,
      'hostname': identity.hostname,
      'platform': identity.platform,
      'boundAt': DateTime.now().toIso8601String(),
    };
    _write(map);
  }

  /// מסיר את השיוך של [identity].
  void unbind(MachineIdentity identity) {
    final map = _read();
    if (map.remove(identity.id) != null) _write(map);
  }

  /// כל השיוכים — למסך שמראה אילו מחשבים נגעו בכונן הזה.
  Map<String, String> allBindings() {
    final out = <String, String>{};
    for (final entry in _read().entries) {
      final value = entry.value;
      if (value is Map && value['profileId'] is String) {
        out[entry.key] = value['profileId'] as String;
      }
    }
    return out;
  }

  Map<String, dynamic> _read() {
    try {
      if (!file.existsSync()) return {};
      final raw = jsonDecode(file.readAsStringSync());
      return raw is Map<String, dynamic> ? raw : {};
    } catch (_) {
      // רישום פגום אינו סיבה לעצור: התוצאה היא פרופיל חדש, לא קריסה.
      return {};
    }
  }

  void _write(Map<String, dynamic> map) {
    final tmp = File('${file.path}.tmp');
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(map),
      flush: true,
    );
    if (file.existsSync()) file.deleteSync();
    tmp.renameSync(file.path);
  }
}

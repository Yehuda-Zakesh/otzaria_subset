import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// גרסת התוכנה, מוזרקת בבנייה מאותה שורת `version` ב-pubspec שה-workflow
/// מעלה. במתכוון אין כאן קבוע כתוב ביד: מקור שני לגרסה נסחף מהראשון
/// בשקט, והתוצאה היא תוכנה שמציעה לעצמה עדכון לגרסה שהיא כבר מריצה.
///
/// ‏`0.0.0` היא בנייה מקומית, ואז אין בדיקת עדכון בכלל — אין גרסה
/// אמיתית להשוות אליה, וכל שחרור היה נראה חדש יותר.
const String kAppVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: '0.0.0');

/// האם הבנייה הזו בכלל אמורה לבדוק עדכונים לעצמה.
bool get kAppVersionIsReleased => kAppVersion != '0.0.0';

const String _releasesApi =
    'https://api.github.com/repos/Yehuda-Zakesh/otzaria_subset/releases/latest';

/// גרסה חדשה של התוכנה שממתינה להורדה.
class AppRelease {
  final String version;
  final Uri downloadUrl;

  /// גודל ההורדה. `0` כשהשרת לא דיווח אותו — אז פשוט לא מציגים אותו.
  final int sizeBytes;

  const AppRelease({
    required this.version,
    required this.downloadUrl,
    required this.sizeBytes,
  });
}

/// בודק אם יצאה גרסה חדשה של **התוכנה** (לא של הספרייה), מוריד אותה
/// ומעביר לה את השרביט.
///
/// ## למה זה יכול להחליף את עצמו בלי הרשאות מנהל
///
/// ההפצה ניידת: `installer/otzaria_subset.iss` פורש תיקייה ליד ה-EXE
/// במקום להתקין ל-Program Files. לכן ההחלפה היא כתיבה לתיקייה של
/// המשתמש, ואין UAC שקופץ בכל גרסה.
class AppUpdater {
  final Duration timeout;

  const AppUpdater({this.timeout = const Duration(seconds: 15)});

  /// מחזיר את הגרסה הממתינה, או `null` אם אין כזו.
  ///
  /// **כל כשל מוחזר כ-`null` ולא נזרק.** רשת שאין, מגבלת קצב של GitHub
  /// או תשובה בפורמט לא מוכר אינם סיבה להפריע למי שבא לגזום ספרים.
  Future<AppRelease?> check() async {
    if (!kAppVersionIsReleased) return null;
    try {
      final response = await http.get(
        Uri.parse(_releasesApi),
        headers: const {'Accept': 'application/vnd.github+json'},
      ).timeout(timeout);
      if (response.statusCode != 200) return null;

      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map<String, dynamic>) return null;

      final version = _stripTag(body['tag_name']);
      if (version == null || _compare(version, kAppVersion) <= 0) return null;

      final assets = body['assets'];
      if (assets is! List) return null;
      for (final asset in assets) {
        if (asset is! Map<String, dynamic>) continue;
        final name = asset['name'];
        final url = asset['browser_download_url'];
        if (name is! String || url is! String) continue;
        if (!name.toLowerCase().endsWith('.exe')) continue;
        return AppRelease(
          version: version,
          downloadUrl: Uri.parse(url),
          sizeBytes: asset['size'] is int ? asset['size'] as int : 0,
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// מוריד את [release] ומפעיל אותו.
  ///
  /// מדווח התקדמות בין 0 ל-1, **ואינו מסתיים בהצלחה**: הפורש חייב
  /// להחליף את ה-exe שרץ כרגע, ולכן האפליקציה נסגרת ברגע שהוא עולה.
  /// יציאה רגילה מההזרמה הזו פירושה כשל.
  Stream<double> install(AppRelease release) async* {
    // נתיב קבוע ולא createTemp: כל עדכון היה משאיר עוד כמה מגהבייטים
    // בתיקייה משלו, ואיש לא היה מנקה אותם.
    final dir =
        Directory(p.join(Directory.systemTemp.path, 'otzaria_subset_update'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'otzaria-subset-update.exe'));

    final client = http.Client();
    try {
      final response = await client
          .send(http.Request('GET', release.downloadUrl))
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw HttpException('קוד ${response.statusCode}',
            uri: release.downloadUrl);
      }
      final total = response.contentLength ?? release.sizeBytes;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) yield (received / total).clamp(0.0, 1.0);
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }

    yield 1;
    await _handOff(file.path);
  }

  /// מפעיל את הפורש על תיקיית ההרצה הנוכחית ויוצא.
  ///
  /// ‏`detached` חובה: תהליך הבן חייב לשרוד את מותנו, שהרי הוא זה
  /// שמחליף אותנו. `/DIR` מצביע על התיקייה שאנחנו רצים ממנה, כדי
  /// שהעדכון ינחת בדיוק במקום שהמשתמש פרש אליו ולא במקום אחר.
  Future<void> _handOff(String setupPath) async {
    final appDir = p.dirname(Platform.resolvedExecutable);
    await Process.start(
      setupPath,
      ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/DIR=$appDir'],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}

/// `v1.2.3` → `1.2.3`. כל דבר אחר מוחזר כ-`null`.
String? _stripTag(Object? tag) {
  if (tag is! String) return null;
  final value = tag.startsWith('v') ? tag.substring(1) : tag;
  return _parts(value) == null ? null : value;
}

List<int>? _parts(String version) {
  final segments = version.split('.');
  if (segments.length != 3) return null;
  final parsed = segments.map(int.tryParse).toList();
  if (parsed.any((n) => n == null)) return null;
  return parsed.cast<int>();
}

/// השוואת `x.y.z`. גרסה שאי אפשר לפרסר נחשבת שווה — עדיף לא להציע
/// עדכון מאשר להציע אותו על סמך ניחוש.
int _compare(String a, String b) {
  final left = _parts(a);
  final right = _parts(b);
  if (left == null || right == null) return 0;
  for (var i = 0; i < 3; i++) {
    final diff = left[i].compareTo(right[i]);
    if (diff != 0) return diff;
  }
  return 0;
}

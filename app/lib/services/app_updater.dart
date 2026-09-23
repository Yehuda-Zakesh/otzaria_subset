import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

  /// ה-SHA-256 שגיטהאב חישב לקובץ (hex באותיות קטנות), או `null` אם לא
  /// דווח. ‏[AppUpdater.install] מסרב להריץ קובץ שלא אומת מולו.
  final String? sha256;

  const AppRelease({
    required this.version,
    required this.downloadUrl,
    required this.sizeBytes,
    this.sha256,
  });
}

/// מפענח את תשובת `releases/latest` לגרסה שממתינה מעל [currentVersion].
/// פונקציה טהורה, כדי שאפשר לבדוק את הפענוח בלי רשת.
AppRelease? parseRelease(Object? body, {required String currentVersion}) {
  if (body is! Map<String, dynamic>) return null;

  final version = _stripTag(body['tag_name']);
  if (version == null || _compare(version, currentVersion) <= 0) return null;

  final assets = body['assets'];
  if (assets is! List) return null;
  for (final asset in assets) {
    if (asset is! Map<String, dynamic>) continue;
    final name = asset['name'];
    final url = asset['browser_download_url'];
    if (name is! String || url is! String) continue;
    // הסיומת היא החוזה, לא השם — ראו §16 ב-AGENTS.md.
    if (!name.toLowerCase().endsWith('.exe')) continue;
    return AppRelease(
      version: version,
      downloadUrl: Uri.parse(url),
      sizeBytes: asset['size'] is int ? asset['size'] as int : 0,
      sha256: parseDigest(asset['digest']),
    );
  }
  return null;
}

/// ‏`sha256:<64 hex>` → ה-hex באותיות קטנות. אלגוריתם אחר או ערך פגום
/// מוחזרים כ-`null` — ואז אין מול מה לאמת, והעדכון לא יותקן.
String? parseDigest(Object? digest) {
  if (digest is! String) return null;
  final match = RegExp(r'^sha256:([0-9a-fA-F]{64})$').firstMatch(digest.trim());
  return match?.group(1)!.toLowerCase();
}

/// בודק אם יצאה גרסה חדשה של **התוכנה** (לא של הספרייה), מוריד אותה
/// ומעביר לה את השרביט.
///
/// ## למה זה יכול להחליף את עצמו בלי הרשאות מנהל
///
/// אין התקנה: ה-EXE שמתפרסם (`installer/stub/stub.cpp`) פורש תיקייה
/// לצדו במקום להתקין ל-Program Files. לכן ההחלפה היא כתיבה לתיקייה של
/// המשתמש, ואין UAC שקופץ בכל גרסה.
class AppUpdater {
  final Duration timeout;

  /// הזרקות לבדיקות בלבד. ‏[client] שהוזרק אינו נסגר כאן — הוא של מי
  /// שהעביר אותו. ‏[downloadDir] ו-[handOff] מחליפים את התיקייה הזמנית
  /// ואת ההפעלה+יציאה, שבבדיקה היו סוגרות את תהליך הבדיקות עצמו.
  final http.Client? client;
  final String? downloadDir;
  final Future<void> Function(String deployerPath)? handOff;

  const AppUpdater({
    this.timeout = const Duration(seconds: 15),
    this.client,
    this.downloadDir,
    this.handOff,
  });

  /// מחזיר את הגרסה הממתינה, או `null` אם אין כזו.
  ///
  /// **כל כשל מוחזר כ-`null` ולא נזרק.** רשת שאין, מגבלת קצב של GitHub
  /// או תשובה בפורמט לא מוכר אינם סיבה להפריע למי שבא לגזום ספרים.
  Future<AppRelease?> check() async {
    if (!kAppVersionIsReleased) return null;
    final web = client ?? http.Client();
    try {
      final response = await web.get(
        Uri.parse(_releasesApi),
        headers: const {'Accept': 'application/vnd.github+json'},
      ).timeout(timeout);
      if (response.statusCode != 200) return null;
      return parseRelease(
        jsonDecode(utf8.decode(response.bodyBytes)),
        currentVersion: kAppVersion,
      );
    } catch (_) {
      return null;
    } finally {
      if (client == null) web.close();
    }
  }

  /// מוריד את [release] ומפעיל אותו.
  ///
  /// מדווח התקדמות בין 0 ל-1, **ואינו מסתיים בהצלחה**: הפורש חייב
  /// להחליף את ה-exe שרץ כרגע, ולכן האפליקציה נסגרת ברגע שהוא עולה.
  /// יציאה רגילה מההזרמה הזו פירושה כשל.
  Stream<double> install(AppRelease release) async* {
    // נכשלים סגור: בלי hash אין דרך לדעת שמה שירד הוא מה שפורסם, ואנחנו
    // עומדים להריץ אותו. גיטהאב מדווח digest לכל asset שהועלה מאז 2025
    // (אומת על v0.1.2), כך שחסר כאן הוא תשובה חריגה ולא שחרור רגיל.
    final expected = release.sha256;
    if (expected == null) {
      throw StateError('לגרסה ${release.version} לא דווח SHA-256 — '
          'לא מתקינים קובץ שאי אפשר לאמת');
    }

    // נתיב קבוע ולא createTemp: כל עדכון היה משאיר עוד כמה מגהבייטים
    // בתיקייה משלו, ואיש לא היה מנקה אותם.
    final dir = Directory(downloadDir ??
        p.join(Directory.systemTemp.path, 'otzaria_subset_update'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'otzaria-subset-update.exe'));

    final web = client ?? http.Client();
    try {
      final response = await web
          .send(http.Request('GET', release.downloadUrl))
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw HttpException('קוד ${response.statusCode}',
            uri: release.downloadUrl);
      }
      final total = response.contentLength ?? release.sizeBytes;
      final sink = file.openWrite();
      // ה-hash מחושב תוך כדי ההזרמה: קריאה שנייה של הקובץ הייתה מכפילה
      // את ה-I/O, ובלאו הכי מה שנבדק הוא בדיוק הבתים שנכתבו.
      final digest = _DigestSink();
      final hasher = sha256.startChunkedConversion(digest);
      var received = 0;
      try {
        // ה-timeout של `send` מכסה רק את הכותרות; חיבור שנתקע באמצע היה
        // משאיר את פס ההורדה תקוע לנצח.
        await for (final chunk
            in response.stream.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          hasher.add(chunk);
          received += chunk.length;
          if (total > 0) yield (received / total).clamp(0.0, 1.0);
        }
      } finally {
        await sink.close();
      }
      hasher.close();
      // קובץ חתוך אינו נושא את החתימה בסופו, והפורש היה מודיע "הקובץ
      // פגום" אחרי שהתוכנה כבר נסגרה.
      final length = response.contentLength;
      if (length != null && received != length) {
        throw HttpException('ההורדה לא הושלמה', uri: release.downloadUrl);
      }
      if (digest.value.toString() != expected) {
        throw HttpException('הקובץ שירד אינו תואם ל-SHA-256 שפורסם',
            uri: release.downloadUrl);
      }
    } catch (_) {
      // קובץ שלא אומת לא נשאר על הדיסק: שום דבר לא אמור להריץ אותו אחר כך.
      try {
        await file.delete();
      } catch (_) {}
      rethrow;
    } finally {
      if (client == null) web.close();
    }

    yield 1;
    await (handOff ?? _handOff)(file.path);
  }

  /// מפעיל את ה-EXE החדש במצב עדכון ויוצא.
  ///
  /// ‏`detached` חובה: תהליך הבן חייב לשרוד את מותנו, שהרי הוא זה
  /// שמחליף אותנו. ה-pid שלנו עובר אליו כדי שימתין שניסגר לפני
  /// שיכתוב — כל עוד אנחנו רצים הקבצים נעולים. התיקייה היא זו שאנחנו
  /// רצים ממנה, כדי שהעדכון ינחת בדיוק במקום שהמשתמש פרש אליו.
  static Future<void> _handOff(String deployerPath) async {
    final appDir = p.dirname(Platform.resolvedExecutable);
    await Process.start(
      deployerPath,
      ['--update', '$pid', appDir],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}

/// יעד ל-`startChunkedConversion`, שמוסר את ה-hash דרך sink ולא כערך.
class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
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

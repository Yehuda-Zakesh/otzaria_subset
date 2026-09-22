import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_updater.dart';

/// פתיחת פנייה בריפו שממנו גם מגיעים העדכונים — ראו [AppUpdater].
const String kIssueUrl =
    'https://github.com/Yehuda-Zakesh/otzaria_subset/issues/new';

/// גבול מעשי לאורך הכתובת שנפתחת בדפדפן. הדיווח המלא ממילא נשמר לקובץ
/// ומועתק ללוח, ולכן קיצוץ כאן אינו אובדן מידע.
const int _maxUrlLength = 1800;

/// יומן קצר של מה שהשתבש, בזיכרון בלבד.
///
/// ## למה טבעת בזיכרון ולא קובץ לוג
///
/// לדיווח דרוש מה שקרה לפני התקלה, לא היסטוריה. קובץ על הדיסק היה דורש
/// סיבוב, ניקוי וגודל מרבי, והיה מצטבר לנצח אצל הרוב שלא מדווח לעולם.
/// חמישים רשומות שנעלמות עם סגירת התוכנה הן בדיוק מה שצריך.
class ErrorLog {
  static final ErrorLog instance = ErrorLog._();

  ErrorLog._();

  static const int _capacity = 50;

  /// רשומה ארוכה היא כמעט תמיד הדפסה של מבנה נתונים, לא מידע — חותכים.
  static const int _maxEntryLength = 600;

  final Queue<String> _entries = Queue<String>();

  /// הרשומות מהישנה לחדשה.
  List<String> get entries => List.unmodifiable(_entries);

  /// מוסיף רשומה מתוארכת, אחרי הסתרת נתיבים אישיים.
  void record(String message) {
    final clean = maskPaths(message.trim());
    final cut = clean.length > _maxEntryLength
        ? '${clean.substring(0, _maxEntryLength)}…'
        : clean;
    _entries.addLast('[${_stamp(DateTime.now())}] $cut');
    while (_entries.length > _capacity) {
      _entries.removeFirst();
    }
  }

  /// שגיאה עם שתי שורות ה-stack הראשונות — מהן יודעים מאיפה היא באה,
  /// וכל השאר הוא רעש שמנפח את הדיווח.
  void recordError(Object error, StackTrace? stack) {
    final frames = (stack?.toString() ?? '')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(2);
    record(['$error', ...frames].join('\n'));
  }
}

/// מחבר את התופסים הגלובליים ליומן.
///
/// ## למה בולעים את השגיאה ולא נותנים לה להפיל
///
/// מי שבאמצע גזימה של ספרייה בת שבעה ג׳יגה־בייט לא אמור לגלות שהחלון
/// נעלם. השגיאה נרשמת, המסך ממשיך, והמשתמש יכול לשלוח דיווח בעצמו.
/// אין כאן `runZonedGuarded`: `PlatformDispatcher.onError` תופס גם את
/// האסינכרוניות, ובלי הסיכון של אתחול Flutter ב-zone אחר.
void installErrorLogging() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    ErrorLog.instance.recordError(details.exception, details.stack);
    previous?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    ErrorLog.instance.recordError(error, stack);
    return true;
  };
}

/// מסתיר נתיבים אישיים.
///
/// שם המשתמש במחשב הוא לרוב שמו הפרטי של מי שמדווח, והוא מופיע בכל
/// נתיב — והדיווח הזה עתיד להיפתח בגיטהאב, לעיני כול.
String maskPaths(String text, {String? home}) {
  final root = home ?? Platform.environment['USERPROFILE'];
  if (root == null || root.isEmpty) return text;
  // שני סוגי המפריד: אותו נתיב מגיע גם עם `\` וגם עם `/`.
  final pattern = RegExp(
    RegExp.escape(root).replaceAll(r'\', r'[\/]'),
    caseSensitive: false,
  );
  return text.replaceAll(pattern, '%USERPROFILE%');
}

/// דיווח תקלה מוכן לשמירה, להעתקה ולפתיחה בגיטהאב.
class ErrorReport {
  /// זהות הבנייה והמכונה — שלוש־ארבע שורות, לא יותר.
  final List<String> header;

  /// היומן מהישן לחדש.
  final List<String> log;

  const ErrorReport({required this.header, required this.log});

  /// אוסף דיווח ממצב התוכנה ברגע זה.
  factory ErrorReport.now({String? libraryPath}) => ErrorReport(
        header: [
          'ספרייה חלקית לאוצריא',
          'גרסה: $_version',
          'מערכת: ${Platform.operatingSystemVersion}',
          'זמן: ${_stamp(DateTime.now(), withDate: true)}',
          if (libraryPath != null) 'ספרייה: ${maskPaths(libraryPath)}',
        ],
        log: ErrorLog.instance.entries,
      );

  /// הטקסט המלא — זה מה שנשמר לקובץ ומועתק ללוח.
  String get text => [
        ...header,
        '',
        'יומן:',
        if (log.isEmpty) '(ריק — לא נרשמה תקלה מאז שהתוכנה עלתה)',
        ...log,
      ].join('\n');

  /// שם קובץ באנגלית בכוונה: הוא נוסע לגיטהאב כקובץ מצורף.
  String get fileName =>
      'otzaria-subset-report-${_stamp(DateTime.now(), forFile: true)}.txt';

  /// שומר את הדיווח בנתיב שנבחר ומחזיר אותו.
  Future<String> saveTo(String path) async {
    await File(path).writeAsString(text);
    return path;
  }

  /// כתובת פתיחת פנייה, עם גוף מוכן.
  ///
  /// מקצצים מראש היומן כלפי מטה עד שהכתובת נכנסת לגבול: מה שקרוב
  /// לתקלה נמצא בסוף, והתחלת היומן היא הדבר הראשון שאפשר לוותר עליו.
  Uri issueUri({int maxLength = _maxUrlLength}) {
    var kept = log.length;
    while (true) {
      final uri =
          _uri(_body(log.sublist(log.length - kept), kept < log.length));
      if (kept == 0 || uri.toString().length <= maxLength) return uri;
      kept--;
    }
  }

  String _body(List<String> tail, bool trimmed) => [
        'מה ניסיתי לעשות: ',
        '',
        'מה קרה: ',
        '',
        '```',
        ...header,
        '',
        ...tail,
        if (trimmed) '(היומן קוצץ — הדיווח המלא בקובץ המצורף)',
        '```',
      ].join('\n');

  Uri _uri(String body) => Uri.parse(kIssueUrl).replace(
        queryParameters: {'title': 'תקלה בגרסה $_version', 'body': body},
      );
}

/// פותח את הכתובת בדפדפן ברירת המחדל. `false` כשלא הסתדר — ואז המסך
/// מציע את הכתובת עצמה, במקום להשאיר את המשתמש בלי כלום.
Future<bool> openInBrowser(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

String get _version => kAppVersionIsReleased ? kAppVersion : 'בנייה מקומית';

String _stamp(DateTime time, {bool withDate = false, bool forFile = false}) {
  String two(int value) => value.toString().padLeft(2, '0');
  final clock = '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  final date = '${time.year}-${two(time.month)}-${two(time.day)}';
  if (forFile) return '$date-${two(time.hour)}${two(time.minute)}';
  return withDate ? '$date $clock' : clock;
}

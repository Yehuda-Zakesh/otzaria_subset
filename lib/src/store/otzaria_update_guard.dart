import 'package:meta/meta.dart';

/// מה שנמצא בהגדרות של אוצריא לגבי עדכון אוטומטי של הספרייה.
@immutable
class OtzariaUpdateSettings {
  /// מאיפה נקראו ההגדרות — לתצוגה כשהקריאה נכשלה.
  final String source;

  /// האם ההגדרות נקראו בהצלחה. `false` **אינו** אומר שהעדכון כבוי, אלא
  /// שאיננו יודעים — וזה מה שמוצג למשתמש.
  final bool found;

  /// המתג הראשי "עדכוני תוכנה וספרים". `null` = לא נרשם, כלומר ברירת
  /// המחדל של אוצריא — **דלוק**.
  final bool? softwareAndBookUpdatesEnabled;

  /// "סינכרון הספרייה באופן אוטומטי". `null` = ברירת מחדל, דלוק.
  final bool? autoSync;

  /// מצב "מנותק" — מכבה כל פעילות רשת, ולכן גם את העדכון.
  final bool? offlineMode;

  const OtzariaUpdateSettings({
    required this.source,
    required this.found,
    this.softwareAndBookUpdatesEnabled,
    this.autoSync,
    this.offlineMode,
  });

  /// האם עדכון הספרייה האוטומטי כבוי **בוודאות**.
  ///
  /// שלוש דרכים לכבות אותו אצל אוצריא, וכל אחת מספיקה. חוסר ידיעה אינו
  /// נחשב כבוי: ברירת המחדל שם דלוקה, ומסד חלקי שנתקל במעדכן דלוק נמחק.
  bool get isDisabled =>
      found &&
      (offlineMode == true ||
          softwareAndBookUpdatesEnabled == false ||
          autoSync == false);

  /// ההסבר שמוצג למשתמש.
  ///
  /// בלי מונחים פנימיים: מה שהוא צריך לדעת הוא שהספרים שהשאיר עלולים
  /// להימחק, לא איך אוצריא מגלה את זה.
  String get explanation {
    if (!found) {
      return 'לא הצלחנו לבדוק את ההגדרות של אוצריא. ייתכן שהיא מותקנת '
          'במקום אחר או שעדיין לא נפתחה. כדאי לוודא בעצמך שעדכון '
          'הספרייה שם כבוי.';
    }
    if (isDisabled) {
      return 'אוצריא לא תעדכן את הספרייה בעצמה, והספרים שבחרת יישארו.';
    }
    return 'אוצריא עדיין מעדכנת את הספרייה בעצמה. בעדכון הבא היא תגלה '
        'שחסרים ספרים, תוריד את כל הספרייה מחדש, וכל מה שחסכת יחזור.';
  }
}

/// הכרעה אם עדכון הספרייה האוטומטי של אוצריא כבוי.
///
/// ## למה רק קריאה
///
/// אוצריא שומרת את ההגדרות בקופסת Hive שהיא טוענת לזיכרון בעלייה
/// וכותבת ממנה בחזרה. כתיבה אליה מבחוץ בזמן שאוצריא פתוחה תידרס בלי
/// אזהרה, ובזמן שהיא סגורה היא עדיין הימור על פורמט פנימי. לכן כאן
/// **מזהים ומנחים**, ולא משנים בכוח.
///
/// ## למה הקריאה עצמה אינה כאן
///
/// הקופסה היא Hive, וקריאתה דורשת תלות שאין לה מקום בחבילת לוגיקה.
/// המחלקה הזו מחזיקה רק את ההכרעה — מה נחשב "כבוי" ומה נחשב "לא ידוע" —
/// וזה החלק שחייב להיות זהה בכל מקום שבודק.
class OtzariaUpdateGuard {
  const OtzariaUpdateGuard();

  /// המתג הראשי: "עדכוני תוכנה וספרים" במסך ההגדרות ← מערכת.
  static const String keySoftwareAndBookUpdates =
      'key-software-and-book-updates-enabled';

  /// "סינכרון הספרייה באופן אוטומטי".
  static const String keyAutoSync = 'key-auto-sync';

  /// מצב "מנותק".
  static const String keyOfflineMode = 'key-offline-mode';

  /// שם קופסת ההגדרות של אוצריא, בשורש הנתונים שלה.
  static const String settingsBoxName = 'app_preferences';

  /// בונה מצב מתוך ערכים גולמיים שנקראו מהקופסה.
  ///
  /// ערך שאינו `bool` אינו מידע: אותו מפתח יכול לשאת טיפוס אחר אם נכתב
  /// פעם אחרת, ו"כבוי" שנגזר מערך כזה הוא בדיוק הטעות המסוכנת כאן.
  OtzariaUpdateSettings fromValues({
    required String source,
    required Map<String, Object?> values,
  }) =>
      OtzariaUpdateSettings(
        source: source,
        found: true,
        softwareAndBookUpdatesEnabled: _bool(values[keySoftwareAndBookUpdates]),
        autoSync: _bool(values[keyAutoSync]),
        offlineMode: _bool(values[keyOfflineMode]),
      );

  /// קריאה שנכשלה — לא ידוע, ולכן גם לא "כבוי".
  OtzariaUpdateSettings unknown(String source) =>
      OtzariaUpdateSettings(source: source, found: false);

  static bool? _bool(Object? value) => value is bool ? value : null;
}

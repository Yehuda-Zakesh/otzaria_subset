/// עיצוב מספרים לתצוגה. מרוכז כאן כדי שכל המסכים יציגו אותו דבר.
library;

const List<String> _units = ['B', 'KB', 'MB', 'GB', 'TB'];

/// גודל בבייטים בקירוב קריא.
String formatBytes(int bytes) {
  // הפרש גדלים יכול לצאת שלילי; בלי זה הוא היה מוצג כ-"-5000000 B".
  if (bytes < 0) return '-${formatBytes(-bytes)}';
  if (bytes < 1024) return '$bytes B';
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < _units.length - 1) {
    value /= 1024;
    unit++;
  }
  var digits = value >= 100 ? 0 : 1;
  // העיגול עצמו יכול לחצות את הסף: 1023.7KB היה מוצג "1024 KB".
  if (double.parse(value.toStringAsFixed(digits)) >= 1024 &&
      unit < _units.length - 1) {
    value /= 1024;
    unit++;
    digits = 1;
  }
  return '${value.toStringAsFixed(digits)} ${_units[unit]}';
}

/// מספר עם מפרידי אלפים.
String formatCount(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// כמות עם שם עצם בעברית: [one] ליחיד ("ספר אחד"), ומספר + [many] לכל
/// השאר — "1 ספרים" נקרא כשגיאה.
String formatQuantity(int value, {required String one, required String many}) =>
    value == 1 ? one : '${formatCount(value)} $many';

/// האם טקסט נושא מונחים פנימיים שאסור שיגיעו למשתמש (§13, §15 ב-AGENTS.md).
///
/// אותיות לטיניות הן כמעט תמיד שם טבלה, שלב מנוע, נתיב או חריגה גולמית;
/// יחידות גודל (GB וכו') הן היוצא מן הכלל.
bool hasInternalTerms(String text) {
  final stripped = text.replaceAll(RegExp(r'\d\s?[KMGT]?B\b'), '');
  return RegExp('[A-Za-z]').hasMatch(stripped) ||
      stripped.contains('סכמ') ||
      stripped.contains('מסד') ||
      stripped.contains('חלקית');
}

/// הודעת שגיאה שמותר להציג. ההודעה המלאה נשמרת ביומן, ומשם לדיווח
/// התקלה — כאן רק מה שמשתמש יכול להבין ולעשות איתו משהו.
String userFacingError(Object error, {required String fallback}) {
  final text = '$error'.trim();
  if (text.isEmpty || hasInternalTerms(text)) return fallback;
  return text;
}

/// תאריך ושעה קצרים, בלי תלות בחבילת לוקליזציה.
String formatDateTime(DateTime? value) {
  if (value == null) return '—';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.day)}.${two(value.month)}.${value.year} '
      '${two(value.hour)}:${two(value.minute)}';
}

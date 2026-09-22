/// עיצוב מספרים לתצוגה. מרוכז כאן כדי שכל המסכים יציגו אותו דבר.
library;

const List<String> _units = ['B', 'KB', 'MB', 'GB', 'TB'];

/// גודל בבייטים בקירוב קריא.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < _units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${_units[unit]}';
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

/// תאריך ושעה קצרים, בלי תלות בחבילת לוקליזציה.
String formatDateTime(DateTime? value) {
  if (value == null) return '—';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.day)}.${two(value.month)}.${value.year} '
      '${two(value.hour)}:${two(value.minute)}';
}

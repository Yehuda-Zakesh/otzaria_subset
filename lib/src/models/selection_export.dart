import 'dart:convert';

import 'package:meta/meta.dart';

import 'subset_spec.dart';

/// בחירה של משתמש כקובץ נייד — ייצוא ממחשב אחד וייבוא במחשב אחר.
///
/// ## למה מייצאים את הכלל ולא רשימת ספרים
///
/// הקובץ נושא את [SubsetSpec] — הכלל של מה **נשאר** — כמו שהוא. המזהים
/// שבו הם המזהים של אפסטרים (`category.id`, `book.id`), שעליהם נשען כל
/// קובץ patch (`upsert_*`/`delete_*` לפי מפתח), ולכן הם זהים בין מחשבים
/// באותה גרסה ונשמרים לאורך עדכונים. כלל קטגוריה ממשיך לעבוד גם במחשב
/// שספרייתו חדשה יותר: ספר שנוסף בינתיים לקטגוריה שנבחרה ייכנס מעצמו.
///
/// [dbVersion] נשמר כמידע: אם הסכמה התחלפה בין הייצוא לייבוא, ייתכן
/// שמזהים הוקצו מחדש, וה-UI יכול להזהיר. מזהה שאינו במסד היעד נופל
/// בבנייה בשקט (`SubsetRebuilder` חותך מול הספרים הקיימים).
///
/// ייבוא מחליף את `SubsetProfile.spec` ודורש בנייה ממסד מלא — כמו כל
/// שינוי בחירה.
@immutable
class SelectionExport {
  /// תג הפורמט. קובץ JSON אחר (פרופיל, תצלום קטלוג) נדחה ולא מתפרש
  /// כבחירה ריקה.
  static const String format = 'otzaria-subset-selection';

  /// גרסת הפורמט. קורא ישן דוחה גרסה חדשה ממנו במקום לנחש.
  static const int version = 1;

  /// הכלל עצמו.
  final SubsetSpec spec;

  /// שם תצוגה חופשי — בדרך כלל שם הפרופיל שממנו יוצא.
  final String? label;

  /// גרסת הספרייה במחשב המייצא.
  final int? dbVersion;

  /// מתי יוצא.
  final DateTime? exportedAt;

  const SelectionExport({
    required this.spec,
    this.label,
    this.dbVersion,
    this.exportedAt,
  });

  Map<String, dynamic> toJson() => {
        'format': format,
        'version': version,
        if (label != null) 'label': label,
        if (dbVersion != null) 'dbVersion': dbVersion,
        if (exportedAt != null)
          'exportedAt': exportedAt!.toUtc().toIso8601String(),
        'spec': spec.toJson(),
      };

  /// טקסט הקובץ, מוזח כדי שיהיה קריא למי שפותח אותו.
  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// ההפך של [toJson]. זורק [FormatException] על כל מה שאינו בחירה תקינה:
  /// פורמט זר, גרסה חדשה מדי, מזהה שאינו מספר שלם, או כלל שאינו שומר
  /// דבר — בנייה ממנו הייתה נדחית בכל מקרה, ועדיף להגיד את זה בייבוא.
  factory SelectionExport.fromJson(Map<String, dynamic> json) {
    if (json['format'] != format) {
      throw const FormatException('הקובץ אינו קובץ בחירה');
    }
    final v = json['version'];
    if (v is! int || v < 1) {
      throw const FormatException('גרסת קובץ הבחירה חסרה או פגומה');
    }
    if (v > version) {
      throw FormatException('קובץ הבחירה נוצר בגרסה חדשה יותר ($v)');
    }
    final rawSpec = json['spec'];
    if (rawSpec is! Map<String, dynamic>) {
      throw const FormatException('קובץ הבחירה אינו מכיל בחירה');
    }
    final spec = SubsetSpec(
      categoryIds: _ids(rawSpec, 'categoryIds'),
      includeBookIds: _ids(rawSpec, 'includeBookIds'),
      excludeBookIds: _ids(rawSpec, 'excludeBookIds'),
    );
    if (spec.isEmpty) {
      throw const FormatException('הבחירה שבקובץ ריקה');
    }

    final label = json['label'];
    final dbv = json['dbVersion'];
    final at = json['exportedAt'];
    return SelectionExport(
      spec: spec,
      label: label is String ? label : null,
      dbVersion: dbv is int ? dbv : null,
      exportedAt: at is String ? DateTime.tryParse(at) : null,
    );
  }

  /// מפענח טקסט קובץ. JSON שבור נזרק כ-[FormatException], כמו כל פגם אחר.
  static SelectionExport decode(String source) {
    final Object? raw;
    try {
      raw = jsonDecode(source);
    } on FormatException {
      throw const FormatException('הקובץ אינו JSON תקין');
    }
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('הקובץ אינו קובץ בחירה');
    }
    return SelectionExport.fromJson(raw);
  }

  /// קפדני יותר מ-`SubsetSpec.fromJson`: שם שדה חסר הוא ריק, אבל ערך
  /// שאינו רשימת מספרים שלמים הוא קובץ פגום ולא בחירה אחרת.
  static Set<int> _ids(Map<String, dynamic> spec, String key) {
    final raw = spec[key];
    if (raw == null) return const {};
    if (raw is! List) {
      throw FormatException('"$key" בקובץ הבחירה אינו רשימה');
    }
    return {
      for (final e in raw)
        if (e is int) e else throw FormatException('מזהה פגום ב-"$key": $e'),
    };
  }
}

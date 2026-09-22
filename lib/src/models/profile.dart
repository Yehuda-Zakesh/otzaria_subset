import 'package:meta/meta.dart';

import 'subset_spec.dart';

/// פרופיל = **מחשב יעד** אחד.
///
/// כונן אחד משמש כמה מחשבים, ולכל מחשב יש `seforim.db` משלו עם בחירה
/// משלו וגרסה משלה. הפרופיל הוא מה שהכונן זוכר על אותו מחשב: מה נבחר,
/// איזו גרסה מותקנת שם, ומה ה-hash של התוצאה בפעם האחרונה.
///
/// **הקבצים יושבים על הכונן, לא על המחשב.** זה מה שמאפשר להגיע למחשב
/// מנותק, לזהות אותו, ולהחיל עליו בדיוק את מה שחסר לו.
@immutable
class SubsetProfile {
  /// מזהה יציב, בטוח לשם קובץ. אינו משתנה כששם התצוגה משתנה.
  final String id;

  /// שם התצוגה שהמשתמש נתן — "המחשב בבית", "לפטופ בית המדרש".
  final String label;

  /// הבחירה של המחשב הזה.
  final SubsetSpec spec;

  /// גרסת הספרייה שמותקנת שם, או `null` אם עוד לא נבנתה ספרייה.
  final int? dbVersion;

  /// גרסת הסכמה של אותו מסד.
  final int? schemaVersion;

  /// ה-hash הלוגי של תת-הקבוצה אחרי הבנייה/העדכון האחרונים.
  ///
  /// **אינו ה-hash של אוצריא ואינו בר-השוואה אליו** — הוא מחושב על מסד
  /// חלקי. הפורמט נושא קידומת `subset:` בדיוק כדי שלא יתחלף. מה שהוא
  /// מזהה: סחף או שחיתות בשרשרת שלנו.
  final String? subsetHash;

  /// הנתיב ל-`seforim.db` של אותו מחשב, אם נרשם. נשמר כדי שהמשתמש לא
  /// יידרש לאתר אותו בכל פעם; חוסר תוקף שלו אינו שגיאה — פשוט שואלים שוב.
  final String? dbPath;

  /// מתי הוחל עדכון בפעם האחרונה.
  final DateTime? lastAppliedAt;

  /// כמה קישורים נותקו בבנייה האחרונה — מוצג כתזכורת מה המשתמש בחר.
  final int severedLinkCount;

  /// האם עץ הקטגוריות של המסד הזה נגזם.
  ///
  /// נשמר ולא נגזר: אי אפשר להסתכל על מסד חלקי ולדעת אם ענף חסר נגזם
  /// או שמעולם לא היה שם. `SubsetUpdater.applyPatch` חייב לקבל את הערך
  /// הזה כדי לסנן את `upsert_category` באותו אופן שבו המסד נבנה.
  final bool categoriesPruned;

  const SubsetProfile({
    required this.id,
    required this.label,
    this.spec = SubsetSpec.empty,
    this.dbVersion,
    this.schemaVersion,
    this.subsetHash,
    this.dbPath,
    this.lastAppliedAt,
    this.severedLinkCount = 0,
    this.categoriesPruned = false,
  });

  /// האם כבר נבנתה ספרייה למחשב הזה.
  bool get hasLibrary => dbVersion != null;

  SubsetProfile copyWith({
    String? label,
    SubsetSpec? spec,
    int? dbVersion,
    int? schemaVersion,
    String? subsetHash,
    String? dbPath,
    DateTime? lastAppliedAt,
    int? severedLinkCount,
    bool? categoriesPruned,
  }) =>
      SubsetProfile(
        id: id,
        label: label ?? this.label,
        spec: spec ?? this.spec,
        dbVersion: dbVersion ?? this.dbVersion,
        schemaVersion: schemaVersion ?? this.schemaVersion,
        subsetHash: subsetHash ?? this.subsetHash,
        dbPath: dbPath ?? this.dbPath,
        lastAppliedAt: lastAppliedAt ?? this.lastAppliedAt,
        severedLinkCount: severedLinkCount ?? this.severedLinkCount,
        categoriesPruned: categoriesPruned ?? this.categoriesPruned,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'spec': spec.toJson(),
        'dbVersion': dbVersion,
        'schemaVersion': schemaVersion,
        'subsetHash': subsetHash,
        'dbPath': dbPath,
        'lastAppliedAt': lastAppliedAt?.toIso8601String(),
        'severedLinkCount': severedLinkCount,
        'categoriesPruned': categoriesPruned,
      };

  factory SubsetProfile.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('פרופיל בלי מזהה');
    }
    final rawDate = json['lastAppliedAt'];
    return SubsetProfile(
      id: id,
      label: json['label'] as String? ?? id,
      spec: json['spec'] is Map<String, dynamic>
          ? SubsetSpec.fromJson(json['spec'] as Map<String, dynamic>)
          : SubsetSpec.empty,
      dbVersion: (json['dbVersion'] as num?)?.toInt(),
      schemaVersion: (json['schemaVersion'] as num?)?.toInt(),
      subsetHash: json['subsetHash'] as String?,
      dbPath: json['dbPath'] as String?,
      lastAppliedAt:
          rawDate is String ? DateTime.tryParse(rawDate) : null,
      severedLinkCount: (json['severedLinkCount'] as num?)?.toInt() ?? 0,
      categoriesPruned: json['categoriesPruned'] == true,
    );
  }

  /// הופך שם חופשי למזהה בטוח לשם קובץ. שם בעברית הוא הרוב כאן, ולכן
  /// ההמרה שומרת אותיות יוניקוד ומחליפה רק מה שמסוכן בנתיב.
  static String slugify(String label) {
    final cleaned = label
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return cleaned.isEmpty ? 'profile' : cleaned;
  }
}

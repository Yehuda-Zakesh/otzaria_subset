import 'package:meta/meta.dart';

/// מה המשתמש בחר — **כלל**, לא תצלום.
///
/// הכלל נשמר ונפתר מחדש בכל עדכון, כדי שספר חדש שנוסף לקטגוריה שנבחרה
/// ייכנס מעצמו. תצלום של מזהי ספרים היה קופא ברגע הבחירה, והמשתמש שבחר
/// "ש״ס בבלי" לא היה מקבל מסכת שנוספה אחר כך.
///
/// [excludeBookIds] גובר על הכל, כדי שהסרה ידנית של ספר בודד מקטגוריה
/// שנבחרה לא תתבטל בעדכון הבא.
@immutable
class SubsetSpec {
  /// קטגוריות שנבחרו. כל צאצאיהן נכללים דרך `category_closure`.
  final Set<int> categoryIds;

  /// ספרים בודדים שנוספו מעבר לקטגוריות.
  final Set<int> includeBookIds;

  /// ספרים שהוסרו במפורש. גובר על [categoryIds] ועל [includeBookIds].
  final Set<int> excludeBookIds;

  const SubsetSpec({
    this.categoryIds = const {},
    this.includeBookIds = const {},
    this.excludeBookIds = const {},
  });

  /// ספרייה ריקה — נקודת הפתיחה של פרופיל חדש.
  static const SubsetSpec empty = SubsetSpec();

  bool get isEmpty =>
      categoryIds.isEmpty && includeBookIds.isEmpty;

  SubsetSpec copyWith({
    Set<int>? categoryIds,
    Set<int>? includeBookIds,
    Set<int>? excludeBookIds,
  }) =>
      SubsetSpec(
        categoryIds: categoryIds ?? this.categoryIds,
        includeBookIds: includeBookIds ?? this.includeBookIds,
        excludeBookIds: excludeBookIds ?? this.excludeBookIds,
      );

  Map<String, dynamic> toJson() => {
        'categoryIds': categoryIds.toList()..sort(),
        'includeBookIds': includeBookIds.toList()..sort(),
        'excludeBookIds': excludeBookIds.toList()..sort(),
      };

  factory SubsetSpec.fromJson(Map<String, dynamic> json) => SubsetSpec(
        categoryIds: _intSet(json['categoryIds']),
        includeBookIds: _intSet(json['includeBookIds']),
        excludeBookIds: _intSet(json['excludeBookIds']),
      );

  static Set<int> _intSet(Object? raw) => raw is List
      ? raw.map((e) => (e as num).toInt()).toSet()
      : const <int>{};

  @override
  bool operator ==(Object other) =>
      other is SubsetSpec &&
      _sameSet(categoryIds, other.categoryIds) &&
      _sameSet(includeBookIds, other.includeBookIds) &&
      _sameSet(excludeBookIds, other.excludeBookIds);

  static bool _sameSet(Set<int> a, Set<int> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  int get hashCode => Object.hash(
        categoryIds.length,
        includeBookIds.length,
        excludeBookIds.length,
      );
}

/// הבחירה כפי שהיא נפתרת מול patch מסוים.
///
/// ## למה יש כאן שתי קבוצות ולא אחת
///
/// קובץ patch נושא **רק את מה שהשתנה**. ספר שהיה קיים באוצריא כבר כמה
/// גרסאות ועובר בגרסה הזו לקטגוריה שהמשתמש בחר מגיע ב-patch עם שורת
/// ‏`book` בלבד — הטקסט שלו לא השתנה, ולכן אינו שם. אין שום דרך להשיג
/// ספר כזה מקובץ עדכון: המידע פשוט אינו בו.
///
/// זו אינה תקלה במסנן אלא תכונה של פורמט הדלתא, ולכן היא מטופלת במפורש:
/// [keep] הם הספרים שאפשר לתחזק דרך ה-patch הזה, ו-[pendingAcquisition]
/// הם ספרים שהכלל בוחר אבל התוכן שלהם אינו זמין — הם ממתינים להבאה
/// ממסד מלא, ועד אז אינם נכנסים לתת-הקבוצה.
///
/// **השקט הוא הסכנה כאן.** בלי ההפרדה הזו ספר כזה היה נכנס לספרייה עם
/// שורת `book` ובלי אף שורת טקסט — נראה קיים, נפתח ריק.
@immutable
class PatchKeepResolution {
  /// הספרים שנכנסים לסינון: קיימים מקומית, או שה-patch מביא את תוכנם.
  final Set<int> keep;

  /// ספרים שהכלל בוחר אך תוכנם אינו ב-patch ואינו מקומי.
  final Set<int> pendingAcquisition;

  /// הקטגוריות שנשמרות — ראו `SubsetResolver.resolveCategoryIds`.
  ///
  /// חייבת לעבור גם ל-`PatchFilter`: `upsert_category` שנשמר לקטגוריה
  /// שנגזמה היה מחזיר אותה למסד, ו-`category.parentId` שלה מצביע
  /// לקטגוריה שאינה שם — כלומר הפרת מפתח זר.
  final Set<int> keepCategories;

  const PatchKeepResolution({
    required this.keep,
    this.pendingAcquisition = const {},
    this.keepCategories = const {},
  });

  bool get hasPending => pendingAcquisition.isNotEmpty;
}

/// ספר שקישורים יוצאים אליו אבל הוא עצמו אינו בבחירה — שורה אחת בדוח
/// שמוצג למשתמש לפני שהוא מאשר.
@immutable
class SeveredLinkTarget {
  final int bookId;
  final String title;

  /// כמה קישורים מהבחירה מצביעים אל הספר הזה (או ממנו אליה).
  final int linkCount;

  /// כמה בייטים הספר הזה היה מוסיף לתת-הקבוצה אילו נכלל.
  final int estimatedBytes;

  const SeveredLinkTarget({
    required this.bookId,
    required this.title,
    required this.linkCount,
    required this.estimatedBytes,
  });
}

/// התוצאה של פתירת [SubsetSpec] מול מסד נתונים: אילו ספרים בפועל, מה
/// המחיר, ומה יינתק.
///
/// זה מה שה-UI מציג לפני ההורדה. המדיניות היא **ניתוק** — קישורים חוצי
/// גבול נמחקים — ו-[severedLinks] הוא בדיוק המחיר של ההחלטה הזו, כדי
/// שהמשתמש יוכל להחליט מדעת אם להוסיף את הספרים החסרים.
@immutable
class SubsetPlan {
  /// מזהי הספרים שייכנסו לתת-הקבוצה.
  final Set<int> bookIds;

  /// אומדן גודל תת-הקבוצה בבייטים.
  final int estimatedBytes;

  /// כמה קישורים יימחקו כי צד אחד שלהם אינו בבחירה.
  final int severedLinkCount;

  /// הספרים שאליהם הקישורים האלה הולכים, ממוינים לפי [linkCount] יורד.
  final List<SeveredLinkTarget> severedLinks;

  const SubsetPlan({
    required this.bookIds,
    required this.estimatedBytes,
    required this.severedLinkCount,
    required this.severedLinks,
  });

  /// כמה היה עולה להוסיף את **כל** הספרים שהקישורים מצביעים אליהם.
  int get closureCostBytes =>
      severedLinks.fold(0, (sum, t) => sum + t.estimatedBytes);

  bool get hasSeveredLinks => severedLinkCount > 0;
}

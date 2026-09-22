/// סיווג כל טבלה בסכמת `seforim.db` לפי מה שקובע אם שורה שייכת לתת-קבוצה.
///
/// זה **לב הפרויקט**. כל השאר — בניית תת-קבוצה, סינון patch, אימות — נגזר
/// מהטבלה שכאן. שינוי כאן משנה את משמעות "ספרייה חלקית".
///
/// הסיווג אומת מול הסכמה האמיתית (schema 5, DB של 7.42GB): כל טבלה
/// שקשורה לספר נושאת `bookId` מפורש ו-`NOT NULL`, ו-`link` נושאת את שני
/// צדי הקישור (`sourceBookId`, `targetBookId`) על השורה עצמה. לכן אין אף
/// טבלה שבה שיוך שורה לספר דורש ניחוש.
library;

import 'package:meta/meta.dart';

/// מה קובע אם שורה נשארת בתת-קבוצה.
enum ScopeKind {
  /// נשמרת במלואה. הטבלאות האלה קטנות (~20MB בסך הכל) ומשותפות בין ספרים,
  /// ושמירתן השלמה היא מה שמשאיר את שמונה אילוצי ה-`UNIQUE` הגלובליים
  /// מתנהגים בדיוק כמו באפסטרים — ראו `AGENTS.md` §5.1 בריפו המעדכן.
  global,

  /// נשמרת כשכל עמודות ה-bookId שב-[TableScope.bookColumns] נמצאות בקבוצה
  /// הנבחרת. עמודה אחת לטבלה רגילה, שתיים לטבלה דו-צדדית (`link`,
  /// `book_base_text`, `default_commentator`, `default_targum`).
  byBook,

  /// נשמרת כששורות ההורה שב-[TableScope.parents] שרדו. טבלאות נגזרות שאין
  /// בהן bookId — ההחלטה עליהן היא בדיקה מקומית של קיום ההורה, בלי שיוך
  /// לספר בכלל.
  byParent,
}

/// הפניה לשורת הורה שחייבת לשרוד כדי שהשורה הזו תישמר.
@immutable
class ParentRef {
  /// העמודה בטבלה הנוכחית.
  final String column;

  /// טבלת ההורה.
  final String table;

  /// העמודה בטבלת ההורה שאליה [column] מצביעה.
  final String parentColumn;

  const ParentRef(this.column, this.table, this.parentColumn);
}

/// סיווג טבלה אחת.
@immutable
class TableScope {
  final String name;
  final ScopeKind kind;

  /// ל-[ScopeKind.byBook]: העמודות שכולן חייבות להיות בקבוצה הנבחרת.
  final List<String> bookColumns;

  /// ל-[ScopeKind.byParent]: שורות ההורה שחייבות לשרוד.
  final List<ParentRef> parents;

  const TableScope.global(this.name)
      : kind = ScopeKind.global,
        bookColumns = const [],
        parents = const [];

  const TableScope.byBook(this.name, this.bookColumns)
      : kind = ScopeKind.byBook,
        parents = const [];

  const TableScope.byParent(this.name, this.parents)
      : kind = ScopeKind.byParent,
        bookColumns = const [];

  /// האם הטבלה נשמרת במלואה ללא תנאי.
  bool get isGlobal => kind == ScopeKind.global;
}

/// הסיווג של כל 37 הטבלאות, **בסדר מפתח זר** — אותו סדר בדיוק כמו
/// `kPatchTablesInFkOrder` בחבילת המעדכן. העתקה לתת-קבוצה רצה בסדר הזה
/// (הורה לפני צאצא); מחיקה רצה בסדר ההפוך.
///
/// `patchTablesContractTest` מוודא שהרשימה כאן מכסה בדיוק את הטבלאות
/// שהמעדכן מכיר — טבלה חדשה בסכמה שלא סווגה כאן תפיל את הבדיקה ולא
/// תיעלם בשקט מתת-הקבוצה.
const List<TableScope> kTableScopesInFkOrder = [
  // ── גלובלי: נשמר במלואו (~20MB) ──
  TableScope.global('source'),
  TableScope.global('author'),
  TableScope.global('topic'),
  TableScope.global('pub_place'),
  TableScope.global('pub_date'),
  TableScope.global('connection_type'),
  // ‏tocText משותפת בין ספרים ויש עליה UNIQUE(text) — גיזום שלה היה מייצר
  // בדיוק את התנגשות ה-UNIQUE שאפסטרים נכווה בה (issue #19 שם).
  TableScope.global('tocText'),
  TableScope.global('generation'),
  TableScope.global('category'),
  TableScope.global('category_closure'),

  // ── ספרים ומטא-דאטה שלהם ──
  TableScope.byBook('book', ['id']),
  TableScope.byBook('book_author', ['bookId']),
  // שני הצדדים הם ספרים: ספר בסיס שלא נבחר מנתק את הקשר.
  TableScope.byBook('book_base_text', ['bookId', 'baseBookId']),
  TableScope.byBook('book_topic', ['bookId']),
  TableScope.byBook('book_pub_place', ['bookId']),
  TableScope.byBook('book_pub_date', ['bookId']),
  TableScope.byBook('book_acronym', ['bookId']),
  TableScope.byBook('book_generation', ['bookId']),

  // ── תוכן ──
  TableScope.byBook('tocEntry', ['bookId']),
  TableScope.byBook('line', ['bookId']),
  // ‏line_toc.lineId ו-tocEntryId שייכים לאותו ספר, ולכן שורדים יחד; שני
  // ההורים רשומים כדי שהבדיקה לא תסתמך על ההנחה הזו.
  TableScope.byParent('line_toc', [
    ParentRef('lineId', 'line', 'id'),
    ParentRef('tocEntryId', 'tocEntry', 'id'),
  ]),
  TableScope.byBook('line_ref', ['bookId']),
  TableScope.byBook('line_dh', ['bookId']),

  // ── קישורים: הטבלה היחידה שבה תת-קבוצה מנתקת משהו אמיתי ──
  // שני צדי הקישור על השורה עצמה, ולכן הסינון הוא בדיקה אחת ולא JOIN.
  // ‏sourceLineId/targetLineId שייכים לאותם ספרים ושורדים איתם.
  TableScope.byBook('link', ['sourceBookId', 'targetBookId']),
  TableScope.byParent('link_anchor', [ParentRef('linkId', 'link', 'id')]),
  TableScope.byParent('link_range', [
    ParentRef('linkId', 'link', 'id'),
    ParentRef('endLineId', 'line', 'id'),
  ]),
  TableScope.byParent('link_coverage', [
    ParentRef('lineId', 'line', 'id'),
    ParentRef('linkId', 'link', 'id'),
  ]),
  TableScope.byParent(
      'link_suppressed_side', [ParentRef('linkId', 'link', 'id')]),
  TableScope.byBook('book_has_links', ['bookId']),

  // ── גרסאות נוסח ──
  TableScope.byBook('book_version', ['bookId']),
  TableScope.byParent('version_line', [
    ParentRef('versionId', 'book_version', 'id'),
    ParentRef('lineId', 'line', 'id'),
  ]),

  // ── מבני TOC חלופיים ──
  TableScope.byBook('alt_toc_structure', ['bookId']),
  // ‏parentId הוא הפניה עצמית בתוך אותו מבנה, ו-textId מצביע ל-tocText
  // שנשמרת במלואה — די בבדיקת המבנה.
  TableScope.byParent(
      'alt_toc_entry', [ParentRef('structureId', 'alt_toc_structure', 'id')]),
  TableScope.byParent('line_alt_toc', [
    ParentRef('lineId', 'line', 'id'),
    ParentRef('structureId', 'alt_toc_structure', 'id'),
    ParentRef('altTocEntryId', 'alt_toc_entry', 'id'),
  ]),

  // ── ברירות מחדל דו-צדדיות ──
  TableScope.byBook('default_commentator', ['bookId', 'commentatorBookId']),
  TableScope.byBook('default_targum', ['bookId', 'targumBookId']),

  // ‏schema_meta נושאת את db_version ו-db_schema_version, שה-preflight של
  // ‏PatchApplier קורא. חייבת לעבור כמות שהיא.
  TableScope.global('schema_meta'),
];

/// מפה משם טבלה לסיווג שלה.
final Map<String, TableScope> kTableScopeByName = {
  for (final scope in kTableScopesInFkOrder) scope.name: scope,
};

/// הטבלאות שנשמרות במלואן.
final List<String> kGlobalTables = [
  for (final s in kTableScopesInFkOrder)
    if (s.isGlobal) s.name,
];

/// הסיווג של [table], או `null` אם הטבלה אינה מסווגת. `null` הוא **תמיד**
/// סיבה לעצור: טבלה לא מסווגת פירושה סכמה שהמנוע הזה לא מכיר.
TableScope? scopeFor(String table) => kTableScopeByName[table];

/// ‏fixtures סינתטיים לבדיקות המנוע.
///
/// **אין כאן שום תוכן מאוצריא.** הספרים הם "ספר 1".."ספר 4" והשורות הן
/// מחרוזות מחוללות. זו לא רק הקפדה על זכויות — בדיקה שתלויה במסד של 7.4GB
/// אינה בדיקה שרצה, והמטרה כאן היא להוכיח את *הלוגיקה* של הסינון, שאינה
/// תלויה בתוכן.
///
/// הסכמה היא תת-קבוצה של הסכמה האמיתית (סכמה 5) — **שמות הטבלאות
/// והעמודות זהים לה בדיוק**, כדי ש-`kTableScopesInFkOrder` יחול עליה בלי
/// שינוי. נבחרו הטבלאות שמכסות את כל ארבעת מצבי הסיווג:
///
/// * גלובלי — `category`, `category_closure`, `tocText`, `author`,
///   `schema_meta`
/// * לפי ספר, עמודה אחת — `book`, `line`, `tocEntry`, `book_author`,
///   `book_version`
/// * לפי ספר, שני צדדים — `link` (`sourceBookId` + `targetBookId`)
/// * לפי הורה — `line_toc`, `link_anchor` (הורה אחד),
///   `version_line` (שני הורים)
library;

import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// ה-DDL של המסד המדומה, בסדר מפתח זר.
const List<String> kFixtureSchema = [
  'CREATE TABLE schema_meta ('
      'key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)',
  'CREATE TABLE author ('
      'id INTEGER PRIMARY KEY NOT NULL, name TEXT NOT NULL UNIQUE)',
  'CREATE TABLE tocText ('
      'id INTEGER PRIMARY KEY NOT NULL, text TEXT NOT NULL UNIQUE)',
  'CREATE TABLE category ('
      'id INTEGER PRIMARY KEY NOT NULL, parentId INTEGER, '
      'title TEXT NOT NULL, level INTEGER NOT NULL DEFAULT 0, '
      'orderIndex INTEGER NOT NULL DEFAULT 999, '
      'FOREIGN KEY (parentId) REFERENCES category(id) ON DELETE CASCADE)',
  'CREATE TABLE category_closure ('
      'ancestorId INTEGER NOT NULL, descendantId INTEGER NOT NULL, '
      'PRIMARY KEY (ancestorId, descendantId), '
      'FOREIGN KEY (ancestorId) REFERENCES category(id) ON DELETE CASCADE, '
      'FOREIGN KEY (descendantId) REFERENCES category(id) ON DELETE CASCADE)',
  'CREATE TABLE book ('
      'id INTEGER PRIMARY KEY NOT NULL, categoryId INTEGER NOT NULL, '
      'title TEXT NOT NULL, totalLines INTEGER NOT NULL DEFAULT 0, '
      'FOREIGN KEY (categoryId) REFERENCES category(id) ON DELETE CASCADE)',
  'CREATE TABLE book_author ('
      'bookId INTEGER NOT NULL, authorId INTEGER NOT NULL, '
      'PRIMARY KEY (bookId, authorId), '
      'FOREIGN KEY (bookId) REFERENCES book(id) ON DELETE CASCADE, '
      'FOREIGN KEY (authorId) REFERENCES author(id) ON DELETE CASCADE)',
  'CREATE TABLE tocEntry ('
      'id INTEGER PRIMARY KEY NOT NULL, bookId INTEGER NOT NULL, '
      'textId INTEGER NOT NULL, level INTEGER NOT NULL, '
      'FOREIGN KEY (bookId) REFERENCES book(id) ON DELETE CASCADE, '
      'FOREIGN KEY (textId) REFERENCES tocText(id) ON DELETE CASCADE)',
  'CREATE TABLE line ('
      'id INTEGER PRIMARY KEY NOT NULL, bookId INTEGER NOT NULL, '
      'lineIndex INTEGER NOT NULL, content TEXT NOT NULL, '
      'charCount INTEGER NOT NULL DEFAULT 0, '
      'FOREIGN KEY (bookId) REFERENCES book(id) ON DELETE CASCADE)',
  'CREATE TABLE line_toc ('
      'lineId INTEGER PRIMARY KEY, tocEntryId INTEGER NOT NULL, '
      'FOREIGN KEY (lineId) REFERENCES line(id) ON DELETE CASCADE, '
      'FOREIGN KEY (tocEntryId) REFERENCES tocEntry(id) ON DELETE CASCADE)',
  'CREATE TABLE link ('
      'id INTEGER PRIMARY KEY NOT NULL, '
      'sourceBookId INTEGER NOT NULL, targetBookId INTEGER NOT NULL, '
      'sourceLineId INTEGER NOT NULL, targetLineId INTEGER NOT NULL, '
      'FOREIGN KEY (sourceBookId) REFERENCES book(id) ON DELETE CASCADE, '
      'FOREIGN KEY (targetBookId) REFERENCES book(id) ON DELETE CASCADE, '
      'FOREIGN KEY (sourceLineId) REFERENCES line(id) ON DELETE CASCADE, '
      'FOREIGN KEY (targetLineId) REFERENCES line(id) ON DELETE CASCADE)',
  'CREATE TABLE link_anchor ('
      'linkId INTEGER NOT NULL, side INTEGER NOT NULL DEFAULT 0, '
      'charStart INTEGER NOT NULL, charEnd INTEGER, label TEXT, '
      'PRIMARY KEY (linkId, side, charStart), '
      'FOREIGN KEY (linkId) REFERENCES link(id) ON DELETE CASCADE)',
  'CREATE TABLE book_version ('
      'id INTEGER PRIMARY KEY NOT NULL, bookId INTEGER NOT NULL, '
      'versionTitle TEXT NOT NULL, '
      'UNIQUE (bookId, versionTitle), '
      'FOREIGN KEY (bookId) REFERENCES book(id) ON DELETE CASCADE)',
  'CREATE TABLE version_line ('
      'versionId INTEGER NOT NULL, lineId INTEGER NOT NULL, '
      'content TEXT NOT NULL, '
      'PRIMARY KEY (versionId, lineId), '
      'FOREIGN KEY (versionId) REFERENCES book_version(id) ON DELETE CASCADE, '
      'FOREIGN KEY (lineId) REFERENCES line(id) ON DELETE CASCADE)',
];

/// הטבלאות שיש להן `upsert_`/`delete_` בקובץ patch מדומה.
const List<String> kFixtureTables = [
  'schema_meta',
  'author',
  'tocText',
  'category',
  'category_closure',
  'book',
  'book_author',
  'tocEntry',
  'line',
  'line_toc',
  'link',
  'link_anchor',
  'book_version',
  'version_line',
];

/// בונה מסד "מלא" מדומה בגרסה [version].
///
/// המבנה: שתי קטגוריות תחת שורש אחד, וארבעה ספרים —
/// ‏1,2 בקטגוריה 10 ("נבחרת"), 3,4 בקטגוריה 11 ("לא נבחרת").
/// קישורים: 1→2 (פנימי), 1→3 ו-4→2 (חוצי גבול, אלה שיינתקו).
void buildFullDb(String path, {int version = 1, int schemaVersion = 5}) {
  final db = sqlite3.sqlite3.open(path);
  try {
    for (final ddl in kFixtureSchema) {
      db.execute(ddl);
    }
    db.execute('PRAGMA foreign_keys = OFF');

    db.execute("INSERT INTO schema_meta VALUES ('db_version', '$version')");
    db.execute("INSERT INTO schema_meta VALUES "
        "('db_schema_version', '$schemaVersion')");

    db.execute("INSERT INTO author VALUES (1, 'מחבר א'), (2, 'מחבר ב')");
    db.execute("INSERT INTO tocText VALUES (1, 'פרק א'), (2, 'פרק ב')");

    db.execute("INSERT INTO category VALUES "
        "(1, NULL, 'שורש', 0, 1), "
        "(10, 1, 'נבחרת', 1, 1), "
        "(11, 1, 'לא נבחרת', 1, 2)");
    // סגור מלא, כולל (x,x) — כמו בטבלה האמיתית.
    db.execute('INSERT INTO category_closure VALUES '
        '(1,1),(1,10),(1,11),(10,10),(11,11)');

    for (var b = 1; b <= 4; b++) {
      final cat = b <= 2 ? 10 : 11;
      db.execute('INSERT INTO book VALUES ($b, $cat, \'ספר $b\', 3)');
      db.execute('INSERT INTO book_author VALUES ($b, ${b.isOdd ? 1 : 2})');
      db.execute('INSERT INTO tocEntry VALUES ($b, $b, 1, 0)');
      db.execute('INSERT INTO book_version VALUES ($b, $b, \'נוסח א\')');
      for (var i = 0; i < 3; i++) {
        final lineId = b * 100 + i;
        db.execute('INSERT INTO line VALUES '
            '($lineId, $b, $i, \'שורה $b/$i\', 8)');
        db.execute('INSERT INTO line_toc VALUES ($lineId, $b)');
        db.execute('INSERT INTO version_line VALUES '
            '($b, $lineId, \'נוסח $b/$i\')');
      }
    }

    // ‏1→2 פנימי; 1→3 ו-4→2 חוצי גבול.
    db.execute('INSERT INTO link VALUES '
        '(1, 1, 2, 100, 200), '
        '(2, 1, 3, 101, 300), '
        '(3, 4, 2, 400, 201)');
    for (var l = 1; l <= 3; l++) {
      db.execute('INSERT INTO link_anchor VALUES ($l, 0, 0, 5, NULL)');
    }
  } finally {
    db.close();
  }
}

/// בונה קובץ `patch.db` מדומה מ-[fromVersion] ל-[toVersion].
///
/// [mutate] מקבל את החיבור הפתוח ויכול למלא טבלאות `upsert_`/`delete_`.
/// כל הטבלאות נוצרות ריקות מראש — בדיוק כמו ב-patch אמיתי, שבו הרוב ריקות.
void buildPatchDb(
  String path, {
  required int fromVersion,
  required int toVersion,
  int patchFormatVersion = 4,
  void Function(sqlite3.Database db)? mutate,
}) {
  final db = sqlite3.sqlite3.open(path);
  try {
    db.execute('CREATE TABLE patch_meta '
        '(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)');
    db.execute('CREATE TABLE migrations '
        '(version INTEGER PRIMARY KEY, sql TEXT NOT NULL)');
    db.execute('CREATE TABLE blobs (name TEXT PRIMARY KEY, content BLOB)');
    db.execute("INSERT INTO patch_meta VALUES "
        "('schema_version', '$patchFormatVersion'), "
        "('from_version', '$fromVersion'), "
        "('to_version', '$toVersion')");

    // טבלאות ה-upsert הן העתק של סכמת היעד בלי ה-FKs; טבלאות ה-delete
    // נושאות את עמודות המפתח הראשי בלבד.
    for (final ddl in kFixtureSchema) {
      final name = _tableNameOf(ddl);
      if (!kFixtureTables.contains(name)) continue;
      db.execute(_stripForeignKeys(ddl).replaceFirst(
        'CREATE TABLE $name (',
        'CREATE TABLE upsert_$name (',
      ));
    }
    for (final entry in _fixturePrimaryKeys.entries) {
      final cols =
          entry.value.map((c) => '"$c" NOT NULL').join(', ');
      final pk = entry.value.map((c) => '"$c"').join(', ');
      db.execute('CREATE TABLE delete_${entry.key} '
          '($cols, PRIMARY KEY ($pk))');
    }

    mutate?.call(db);
  } finally {
    db.close();
  }
}

/// עמודות המפתח הראשי של טבלאות ה-fixture — חייב להסכים עם
/// ‏`kPatchTablesInFkOrder` של החבילה המעדכנת.
const Map<String, List<String>> _fixturePrimaryKeys = {
  'schema_meta': ['key'],
  'author': ['id'],
  'tocText': ['id'],
  'category': ['id'],
  'category_closure': ['ancestorId', 'descendantId'],
  'book': ['id'],
  'book_author': ['bookId', 'authorId'],
  'tocEntry': ['id'],
  'line': ['id'],
  'line_toc': ['lineId'],
  'link': ['id'],
  'link_anchor': ['linkId', 'side', 'charStart'],
  'book_version': ['id'],
  'version_line': ['versionId', 'lineId'],
};

String _tableNameOf(String ddl) =>
    RegExp(r'CREATE TABLE (\w+)').firstMatch(ddl)!.group(1)!;

/// מסיר סעיפי `FOREIGN KEY` ו-`UNIQUE` מ-DDL. טבלת `upsert_` היא מאגר
/// שורות זמני ואינה אוכפת דבר — בדיוק כמו ב-patch אמיתי, שבו שורה יכולה
/// להצביע לספר שיתווסף באותה החלה.
String _stripForeignKeys(String ddl) {
  var out = ddl.replaceAll(
    RegExp(r',\s*FOREIGN KEY \([^)]*\) REFERENCES \w+\([^)]*\)'
        r'(\s+ON DELETE (CASCADE|SET NULL|RESTRICT))?'),
    '',
  );
  out = out.replaceAll(RegExp(r',\s*UNIQUE \([^)]*\)'), '');
  out = out.replaceAll(' UNIQUE', '');
  return out;
}

/// יוצר תיקייה זמנית לבדיקה ומחזיר אותה.
Directory createTempDir(String prefix) =>
    Directory.systemTemp.createTempSync('otzaria_subset_$prefix');

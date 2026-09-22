import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// קטגוריה אחת בעץ, כפי שהיא נקראת מהמסד.
@immutable
class CatalogCategory {
  final int id;
  final int? parentId;
  final String title;
  final int level;
  final int orderIndex;

  const CatalogCategory({
    required this.id,
    required this.parentId,
    required this.title,
    required this.level,
    required this.orderIndex,
  });
}

/// ספר אחד. [totalLines] הוא הבסיס לאומדן הגודל ב-`SubsetResolver`,
/// ולכן נקרא כאן כדי שה-UI יוכל להראות מחיר לפני שבוחרים.
@immutable
class CatalogBook {
  final int id;
  final int categoryId;
  final String title;
  final int totalLines;

  const CatalogBook({
    required this.id,
    required this.categoryId,
    required this.title,
    required this.totalLines,
  });
}

/// עץ הקטגוריות והספרים — מה שמסך הבחירה מציג.
///
/// **נקרא פעם אחת ונשמר בזיכרון.** העץ הוא אלפי שורות של מטא-דאטה בלבד
/// (מזהה, שם, מונה שורות), ואילו כל סימון בעץ היה אחרת שולח שאילתה
/// למסד של 7.4GB. הקריאה עצמה כבדה מספיק כדי לרוץ ב-`Isolate`.
class LibraryCatalog {
  final List<CatalogCategory> categories;
  final List<CatalogBook> books;

  /// קטגוריות בנות לפי מזהה הורה, ממוינות כמו שאוצריא מציגה אותן.
  final Map<int, List<CatalogCategory>> childrenOf;

  /// ספרים לפי קטגוריה ישירה.
  final Map<int, List<CatalogBook>> booksOf;

  /// הורה לפי מזהה קטגוריה. נבנה פעם אחת: טיפוס בעץ חוזר על עצמו לכל
  /// שורה שמוצגת, וסריקה לינארית שם הופכת את המסך לאיטי.
  final Map<int, int?> parentOf;

  /// שורשי העץ — קטגוריות בלי הורה.
  final List<CatalogCategory> roots;

  LibraryCatalog._({
    required this.categories,
    required this.books,
    required this.childrenOf,
    required this.booksOf,
    required this.parentOf,
    required this.roots,
  });

  factory LibraryCatalog(
    List<CatalogCategory> categories,
    List<CatalogBook> books,
  ) {
    final childrenOf = <int, List<CatalogCategory>>{};
    final roots = <CatalogCategory>[];
    final known = {for (final c in categories) c.id};
    for (final c in categories) {
      // הורה שאינו במסד פירושו ענף שנגזם — הקטגוריה מוצגת כשורש ולא
      // נעלמת, אחרת ספריה היו בלתי נגישים בעץ.
      final parent = c.parentId;
      if (parent == null || !known.contains(parent)) {
        roots.add(c);
      } else {
        childrenOf.putIfAbsent(parent, () => []).add(c);
      }
    }
    final booksOf = <int, List<CatalogBook>>{};
    for (final b in books) {
      booksOf.putIfAbsent(b.categoryId, () => []).add(b);
    }
    int byOrder(CatalogCategory a, CatalogCategory b) =>
        a.orderIndex != b.orderIndex
            ? a.orderIndex.compareTo(b.orderIndex)
            : a.title.compareTo(b.title);
    roots.sort(byOrder);
    for (final list in childrenOf.values) {
      list.sort(byOrder);
    }
    for (final list in booksOf.values) {
      list.sort((a, b) => a.title.compareTo(b.title));
    }
    return LibraryCatalog._(
      categories: categories,
      books: books,
      childrenOf: childrenOf,
      booksOf: booksOf,
      parentOf: {for (final c in categories) c.id: c.parentId},
      roots: roots,
    );
  }

  static final LibraryCatalog empty = LibraryCatalog(const [], const []);

  /// כל הקטגוריות שתחת [id], כולל עצמה. נגזר מהעץ שבזיכרון ולא
  /// מ-`category_closure`, כדי שסימון בעץ לא יריץ שאילתה.
  Set<int> descendantsOf(int id) {
    final out = <int>{};
    final stack = <int>[id];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      if (!out.add(current)) continue;
      for (final child in childrenOf[current] ?? const <CatalogCategory>[]) {
        stack.add(child.id);
      }
    }
    return out;
  }

  /// כל הספרים שתחת [id] בכל עומק.
  List<CatalogBook> booksUnder(int id) => [
        for (final categoryId in descendantsOf(id))
          ...booksOf[categoryId] ?? const <CatalogBook>[],
      ];

  int get bookCount => books.length;
  int get categoryCount => categories.length;
}

/// קורא את הקטלוג ממסד **פתוח**. הקורא אחראי לפתיחה ולסגירה.
LibraryCatalog readCatalog(sqlite3.Database db) {
  final categories = <CatalogCategory>[];
  for (final row in db.select(
    'SELECT id, parentId, title, level, orderIndex FROM category',
  )) {
    categories.add(CatalogCategory(
      id: (row['id'] as num).toInt(),
      parentId: (row['parentId'] as num?)?.toInt(),
      title: row['title'] as String? ?? '',
      level: (row['level'] as num?)?.toInt() ?? 0,
      orderIndex: (row['orderIndex'] as num?)?.toInt() ?? 999,
    ));
  }
  final books = <CatalogBook>[];
  for (final row in db.select(
    'SELECT id, categoryId, title, totalLines FROM book',
  )) {
    books.add(CatalogBook(
      id: (row['id'] as num).toInt(),
      categoryId: (row['categoryId'] as num).toInt(),
      title: row['title'] as String? ?? '',
      totalLines: (row['totalLines'] as num?)?.toInt() ?? 0,
    ));
  }
  return LibraryCatalog(categories, books);
}

/// פותח את [path] **לקריאה בלבד** וקורא ממנו את הקטלוג.
///
/// פונקציה גלובלית שמקבלת מחרוזת בלבד, כדי שאפשר יהיה להריץ אותה
/// ישירות ב-`Isolate.run` — ראו §9 ב-AGENTS.md.
LibraryCatalog readCatalogFromPath(String path) {
  final db = sqlite3.sqlite3.open(path, mode: sqlite3.OpenMode.readOnly);
  try {
    return readCatalog(db);
  } finally {
    db.close();
  }
}

/// מצב הספרייה שעל הדיסק — מה שמסך "מצב הספרייה" מציג.
@immutable
class LibraryStats {
  final int? dbVersion;
  final int? schemaVersion;
  final int bookCount;
  final int categoryCount;
  final int lineCount;
  final int fileBytes;

  const LibraryStats({
    required this.dbVersion,
    required this.schemaVersion,
    required this.bookCount,
    required this.categoryCount,
    required this.lineCount,
    required this.fileBytes,
  });
}

/// ספירות וגרסאות ממסד פתוח. [fileBytes] מגיע מהקורא — גודל הקובץ
/// אינו נתון של SQLite.
LibraryStats readLibraryStats(sqlite3.Database db, {required int fileBytes}) {
  int countOf(String table) =>
      (db.select('SELECT COUNT(*) AS n FROM $table').first['n'] as num).toInt();
  int? metaInt(String key) {
    final rows = db.select(
      'SELECT value FROM schema_meta WHERE key = ?',
      [key],
    );
    if (rows.isEmpty) return null;
    return int.tryParse(rows.first['value'].toString());
  }

  return LibraryStats(
    dbVersion: metaInt('db_version'),
    schemaVersion: metaInt('db_schema_version'),
    bookCount: countOf('book'),
    categoryCount: countOf('category'),
    lineCount: countOf('line'),
    fileBytes: fileBytes,
  );
}

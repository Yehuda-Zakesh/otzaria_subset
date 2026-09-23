import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'subset_resolver.dart';

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
///
/// ## תצלום של הספרייה המלאה
///
/// קטלוג שנקרא מספרייה שכבר גוזמה אינו רואה את מה שנמחק, ולכן אין ממנו
/// דרך לשחזר. [toJson]/[LibraryCatalog.fromJson] מאפשרים לשמור את הקטלוג
/// של המסד **המלא** בגיזום הראשון, ולהציג ממנו אחר כך מה אפשר להחזיר —
/// ראו `restorableCatalog` ו-`restoreSpecFor`.
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

  /// בייטים לשורה, מכויל על המסד שממנו נקרא הקטלוג — ראו
  /// `calibrateBytesPerLine`. `0` כשאין כיול (קטלוג שנבנה ידנית, או מסד
  /// קטן מהרצפה הגלובלית), ואז כל אומדני הגודל הם `0`.
  final double bytesPerLine;

  /// גרסת הספרייה שממנה נקרא הקטלוג, אם המסד מצהיר עליה.
  final int? dbVersion;

  LibraryCatalog._({
    required this.categories,
    required this.books,
    required this.childrenOf,
    required this.booksOf,
    required this.parentOf,
    required this.roots,
    required this.bytesPerLine,
    required this.dbVersion,
  });

  factory LibraryCatalog(
    List<CatalogCategory> categories,
    List<CatalogBook> books, {
    double bytesPerLine = 0,
    int? dbVersion,
  }) {
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
      bytesPerLine:
          bytesPerLine.isFinite && bytesPerLine > 0 ? bytesPerLine : 0,
      dbVersion: dbVersion,
    );
  }

  static final LibraryCatalog empty = LibraryCatalog(const [], const []);

  /// אותו קטלוג עם כיול אחר. שימושי כשהקטלוג נקרא מספרייה גזומה: הכיול
  /// שלה מעוות (הטבלאות הגלובליות נשארות במלואן), ועדיף הכיול של התצלום
  /// המלא.
  LibraryCatalog withBytesPerLine(double bytesPerLine) => LibraryCatalog(
        categories,
        books,
        bytesPerLine: bytesPerLine,
        dbVersion: dbVersion,
      );

  /// ספר לפי מזהה, או `null`.
  CatalogBook? bookById(int id) => _bookById[id];

  late final Map<int, CatalogBook> _bookById = {
    for (final b in books) b.id: b,
  };

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

  /// הקטגוריה ואבותיה, מלמטה למעלה. מוגן מפני מעגל במסד פגום.
  List<int> ancestorsAndSelf(int categoryId) {
    final out = <int>[];
    final seen = <int>{};
    int? current = categoryId;
    while (current != null && seen.add(current)) {
      out.add(current);
      current = parentOf[current];
    }
    return out;
  }

  /// כל הספרים שתחת [id] בכל עומק.
  List<CatalogBook> booksUnder(int id) => [
        for (final categoryId in descendantsOf(id))
          ...booksOf[categoryId] ?? const <CatalogBook>[],
      ];

  // ── גדלים ──────────────────────────────────────────────────────────

  /// אומדן הגודל שספר מוסיף לספרייה, באותה נוסחה של
  /// `SubsetResolver` (כולל מקדם הביטחון), כדי שסכום העץ יסכים עם המחיר
  /// שמוצג לפני הבנייה.
  int estimatedBytesOf(CatalogBook book) => _bytesFor(book.totalLines);

  /// סך השורות תחת [categoryId] בכל עומק. מחושב פעם אחת לכל העץ: מיון
  /// לפי גודל שואל את זה לכל צומת, וסריקה לכל שאלה הייתה ריבועית.
  int linesUnder(int categoryId) => _linesUnder[categoryId] ?? 0;

  /// אומדן הגודל של כל הספרים תחת [categoryId] בכל עומק.
  int bytesUnder(int categoryId) => _bytesFor(linesUnder(categoryId));

  int _bytesFor(int lines) =>
      (lines * bytesPerLine * SubsetResolver.sizeSafetyFactor).round();

  late final Map<int, int> _linesUnder = () {
    final out = <int, int>{};
    for (final book in books) {
      if (book.totalLines == 0) continue;
      for (final id in ancestorsAndSelf(book.categoryId)) {
        out[id] = (out[id] ?? 0) + book.totalLines;
      }
    }
    return out;
  }();

  int get bookCount => books.length;
  int get categoryCount => categories.length;

  // ── JSON ───────────────────────────────────────────────────────────

  /// תג הפורמט. קובץ אחר שיגיע לכאן בטעות נדחה ולא נקרא כקטלוג ריק.
  static const String jsonFormat = 'otzaria-subset-catalog';

  /// גרסת הפורמט. קורא ישן דוחה גרסה חדשה ממנו במקום לנחש.
  static const int jsonVersion = 1;

  /// JSON קומפקטי: שורה היא מערך ולא אובייקט, כי הקטלוג הוא אלפי ספרים
  /// ושמות שדות חוזרים היו מכפילים את גודל הקובץ.
  ///
  /// `categories`: `[id, parentId, title, level, orderIndex]`;
  /// `books`: `[id, categoryId, title, totalLines]`.
  Map<String, dynamic> toJson() => {
        'format': jsonFormat,
        'version': jsonVersion,
        'dbVersion': dbVersion,
        'bytesPerLine': bytesPerLine,
        'categories': [
          for (final c in categories)
            [c.id, c.parentId, c.title, c.level, c.orderIndex],
        ],
        'books': [
          for (final b in books) [b.id, b.categoryId, b.title, b.totalLines],
        ],
      };

  /// ההפך של [toJson]. זורק [FormatException] על פורמט זר, גרסה חדשה
  /// מדי או שורה פגומה — תצלום חלקי היה מציג "אין מה לשחזר" בשקט.
  factory LibraryCatalog.fromJson(Map<String, dynamic> json) {
    if (json['format'] != jsonFormat) {
      throw const FormatException('הקובץ אינו תצלום קטלוג');
    }
    final version = json['version'];
    if (version is! int || version < 1) {
      throw const FormatException('גרסת תצלום הקטלוג חסרה או פגומה');
    }
    if (version > jsonVersion) {
      throw FormatException('תצלום הקטלוג נוצר בגרסה חדשה יותר ($version)');
    }

    List<Object?> rows(String key, int width) {
      final raw = json[key];
      if (raw is! List) throw FormatException('חסר "$key" בתצלום הקטלוג');
      for (final row in raw) {
        if (row is! List || row.length != width) {
          throw FormatException('שורה פגומה ב-"$key": $row');
        }
      }
      return raw;
    }

    int asInt(Object? v) {
      if (v is int) return v;
      throw FormatException('ערך שאינו מספר שלם בתצלום הקטלוג: $v');
    }

    String asString(Object? v) {
      if (v is String) return v;
      throw FormatException('ערך שאינו מחרוזת בתצלום הקטלוג: $v');
    }

    final categories = [
      for (final row in rows('categories', 5).cast<List<Object?>>())
        CatalogCategory(
          id: asInt(row[0]),
          parentId: row[1] == null ? null : asInt(row[1]),
          title: asString(row[2]),
          level: asInt(row[3]),
          orderIndex: asInt(row[4]),
        ),
    ];
    final books = [
      for (final row in rows('books', 4).cast<List<Object?>>())
        CatalogBook(
          id: asInt(row[0]),
          categoryId: asInt(row[1]),
          title: asString(row[2]),
          totalLines: asInt(row[3]),
        ),
    ];
    final bpl = json['bytesPerLine'];
    final dbv = json['dbVersion'];
    return LibraryCatalog(
      categories,
      books,
      bytesPerLine: bpl is num ? bpl.toDouble() : 0,
      dbVersion: dbv is int ? dbv : null,
    );
  }
}

/// קורא את הקטלוג ממסד **פתוח**. הקורא אחראי לפתיחה ולסגירה.
///
/// מעבר לשתי הטבלאות הקטנות קורא רק `PRAGMA` וסכום של `book.totalLines`
/// לכיול הגודל — לא נוגע ב-`line`, כדי שהטעינה תישאר עניין של שניות.
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
  return LibraryCatalog(
    categories,
    books,
    bytesPerLine: calibrateBytesPerLine(db),
    dbVersion: _dbVersionOf(db),
  );
}

/// ‏`schema_meta.db_version`, או `null`. מסד בלי הטבלה אינו שגיאה כאן —
/// הגרסה היא מידע נלווה לתצלום, לא תנאי לקריאתו.
int? _dbVersionOf(sqlite3.Database db) {
  final hasMeta = db
      .select(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='schema_meta'",
      )
      .isNotEmpty;
  if (!hasMeta) return null;
  final rows = db.select(
    "SELECT value FROM schema_meta WHERE key = 'db_version'",
  );
  if (rows.isEmpty) return null;
  return int.tryParse(rows.first['value'].toString());
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

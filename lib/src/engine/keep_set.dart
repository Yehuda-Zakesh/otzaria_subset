import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// טבלת העזר שנושאת את מזהי הספרים הנבחרים בתוך חיבור SQLite פתוח.
///
/// כל סינון במנוע הזה הוא בסופו של דבר `... IN (SELECT bookId FROM _keep)`.
/// הקבוצה יושבת ב-`temp` ולא ב-`main`: היא לא צריכה להישאר בקובץ התוצאה,
/// ובסכמת `temp` היא נראית לכל השאילתות באותו חיבור, כולל כאלה שחוצות
/// ‏`ATTACH`.
///
/// **למה טבלה ולא `IN (?, ?, ...)`:** בחירת "כל התנ״ך עם מפרשים" היא אלפי
/// מזהים, ו-SQLite מגביל את מספר הפרמטרים (`SQLITE_MAX_VARIABLE_NUMBER`,
/// 999 בברירת מחדל בבנייות רבות). רשימה משורשרת לתוך ה-SQL הייתה עוקפת
/// את המגבלה במחיר תוכנית שאילתה גרועה ובלי אינדקס.
class KeepSet {
  /// שם הטבלה בסכמת `temp`.
  static const String table = 'temp._keep';

  /// תת-שאילתה שמחזירה את כל המזהים הנבחרים — מה שנכנס לכל `IN (...)`.
  static const String selectIds = 'SELECT bookId FROM $table';

  const KeepSet._();

  /// יוצרת את הטבלה וממלאת אותה ב-[bookIds]. קוראת שוב מאפסת את התוכן,
  /// כדי שפתירה מחדש של אותו חיבור לא תערבב שתי בחירות.
  static void install(sqlite3.Database db, Iterable<int> bookIds) {
    db.execute('CREATE TEMP TABLE IF NOT EXISTS _keep '
        '(bookId INTEGER PRIMARY KEY NOT NULL)');
    db.execute('DELETE FROM $table');
    final stmt = db.prepare('INSERT OR IGNORE INTO $table (bookId) VALUES (?)');
    // בתוך transaction של הקורא BEGIN נכשל, וה-ROLLBACK שאחריו היה מבטל
    // את כל העבודה שלו. אז מצטרפים ל-transaction הקיים במקום לפתוח חדש.
    final ownTx = db.autocommit;
    try {
      if (ownTx) db.execute('BEGIN');
      for (final id in bookIds) {
        stmt.execute([id]);
      }
      if (ownTx) db.execute('COMMIT');
    } catch (_) {
      if (ownTx) {
        try {
          db.execute('ROLLBACK');
        } catch (_) {}
      }
      rethrow;
    } finally {
      stmt.close();
    }
  }

  /// כמה מזהים יש בקבוצה.
  static int count(sqlite3.Database db) =>
      db.select('SELECT COUNT(*) c FROM $table').first['c'] as int;

  /// מסירה את הטבלה. לא חובה — היא נעלמת עם סגירת החיבור.
  static void drop(sqlite3.Database db) {
    db.execute('DROP TABLE IF EXISTS $table');
  }
}

/// אותו דבר למזהי **קטגוריות**, לגיזום עץ הקטגוריות.
///
/// ## למה עץ הקטגוריות נגזם בכלל
///
/// אוצריא בונה את עץ הספרייה מ**כל** שורות `category` בלי לסנן קטגוריה
/// ריקה (`buildLibraryCatalog`), והמשתמש מגלה שענף ריק רק אחרי שהוא נכנס
/// אליו. בספרייה חלקית זה רוב העץ.
///
/// ## למה זה בטוח, בשונה משאר הטבלאות הגלובליות
///
/// הטבלאות הגלובליות נשמרות שלמות כדי לא לשבור את שמונה אילוצי
/// ה-`UNIQUE` על עמודות תוכן (`tocText.text`, `author.name`…). ל-`category`
/// **אין** אילוץ כזה — יש לה `id, parentId, title, level, orderIndex,
/// heShortDesc, heDesc` וזה הכל — ו-`category_closure` היא טבלת מפתח
/// טהורה. לכן גיזום שלהן אינו נוגע בחוזה ההתנגשויות.
///
/// ## הכלל
///
/// קטגוריה נשמרת אם היא **אב של ספר שנבחר** (כדי שהנתיב בעץ ייפתר),
/// **או צאצא של קטגוריה שנבחרה** — התנאי השני הוא מה שמאפשר לספר חדש
/// שייכנס לקטגוריה שנבחרה להיפתר נכון ב-`resolveForPatch`. בלעדיו גיזום
/// העץ היה הורג את היכולת לקבל ספרים חדשים.
class CategoryKeepSet {
  /// שם הטבלה בסכמת `temp`.
  static const String table = 'temp._keep_category';

  /// תת-שאילתה שמחזירה את כל מזהי הקטגוריות שנשמרות.
  static const String selectIds = 'SELECT categoryId FROM $table';

  const CategoryKeepSet._();

  /// יוצרת את הטבלה וממלאת אותה ב-[categoryIds].
  static void install(sqlite3.Database db, Iterable<int> categoryIds) {
    db.execute('CREATE TEMP TABLE IF NOT EXISTS _keep_category '
        '(categoryId INTEGER PRIMARY KEY NOT NULL)');
    db.execute('DELETE FROM $table');
    final stmt =
        db.prepare('INSERT OR IGNORE INTO $table (categoryId) VALUES (?)');
    // בתוך transaction של הקורא BEGIN נכשל, וה-ROLLBACK שאחריו היה מבטל
    // את כל העבודה שלו. אז מצטרפים ל-transaction הקיים במקום לפתוח חדש.
    final ownTx = db.autocommit;
    try {
      if (ownTx) db.execute('BEGIN');
      for (final id in categoryIds) {
        stmt.execute([id]);
      }
      if (ownTx) db.execute('COMMIT');
    } catch (_) {
      if (ownTx) {
        try {
          db.execute('ROLLBACK');
        } catch (_) {}
      }
      rethrow;
    } finally {
      stmt.close();
    }
  }

  /// כמה קטגוריות בקבוצה.
  static int count(sqlite3.Database db) =>
      db.select('SELECT COUNT(*) c FROM $table').first['c'] as int;

  /// מסירה את הטבלה.
  static void drop(sqlite3.Database db) {
    db.execute('DROP TABLE IF EXISTS $table');
  }
}

/// תנאי ה-`WHERE` שגוזם את עץ הקטגוריות, או `null` אם [table] אינה אחת
/// משתי טבלאות הקטגוריות או שהגיזום כבוי.
///
/// חי כאן ולא ב-`SubsetBuilder` כדי שהבנייה והסינון ישתמשו **באותו
/// תנאי בדיוק**. שני עותקים שנסחפו זה מזה היו נותנים מסד שנבנה עם קבוצת
/// קטגוריות אחת ומתעדכן לפי אחרת — כלומר `upsert_category` שמחזיר
/// קטגוריה שנגזמה, ו-`parentId` שמצביע לשורה חסרה.
///
/// **`category_closure` דורשת ששני הצדדים יישמרו.** שורה שרק אחד מצדיה
/// נשאר היא הפרת מפתח זר, כי שתי העמודות מצביעות ל-`category(id)`.
String? categoryPruneWhere(String table, bool pruneCategories) {
  if (!pruneCategories) return null;
  switch (table) {
    case 'category':
      return 'WHERE "id" IN (${CategoryKeepSet.selectIds})';
    case 'category_closure':
      return 'WHERE "ancestorId" IN (${CategoryKeepSet.selectIds}) '
          'AND "descendantId" IN (${CategoryKeepSet.selectIds})';
    default:
      return null;
  }
}

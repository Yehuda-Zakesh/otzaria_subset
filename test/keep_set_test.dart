import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// בדיקות ל-[KeepSet] — טבלת העזר שנושאת את הבחירה בתוך חיבור פתוח.
///
/// כל סינון במנוע הוא `IN (SELECT bookId FROM temp._keep)`, ולכן טעות כאן
/// אינה נראית כשגיאה אלא כספרייה עם ספרים לא נכונים. הבדיקות רצות
/// ב-in-memory כי אין להן שום צורך בקובץ.
void main() {
  late sqlite3.Database db;

  setUp(() => db = sqlite3.sqlite3.openInMemory());
  tearDown(() => db.close());

  group('KeepSet', () {
    test('התקנה משקפת את המזהים שהוכנסו', () {
      KeepSet.install(db, {1, 2, 3});
      expect(KeepSet.count(db), 3);
      expect(
        db.select(KeepSet.selectIds).map((r) => r['bookId']).toSet(),
        {1, 2, 3},
      );
    });

    test('התקנה שנייה מחליפה את הקבוצה ואינה מצטברת', () {
      // פתירה מחדש של אותו חיבור חייבת להחליף בחירה. הצטברות הייתה
      // מייצרת ספרייה שמכילה גם ספרים מהבחירה הקודמת, בשקט.
      KeepSet.install(db, {1, 2, 3});
      KeepSet.install(db, {7});
      expect(KeepSet.count(db), 1);
      expect(db.select(KeepSet.selectIds).single['bookId'], 7);
    });

    test('קבוצה ריקה תקפה ומחזירה אפס', () {
      // בחירה ריקה היא מצב לגיטימי (פרופיל חדש), לא שגיאה.
      KeepSet.install(db, const <int>{});
      expect(KeepSet.count(db), 0);
    });

    test('התקנה ריקה אחרי קבוצה מלאה מאפסת', () {
      KeepSet.install(db, {1, 2});
      KeepSet.install(db, const <int>[]);
      expect(KeepSet.count(db), 0);
    });

    test('מזהים כפולים בקלט מתאחדים', () {
      // ה-INSERT OR IGNORE מונע כשל על קלט עם חזרות (איחוד קטגוריות
      // חופפות מייצר בדיוק כאלה).
      KeepSet.install(db, const [1, 1, 2, 2, 2, 3]);
      expect(KeepSet.count(db), 3);
    });

    test('קבוצה גדולה (5000 מזהים) עוברת', () {
      // זו כל הסיבה לטבלה זמנית: רשימת `IN (?,?,...)` הייתה נשברת על
      // ‏SQLITE_MAX_VARIABLE_NUMBER (999 בברירת מחדל) ובחירה של "כל
      // התנ״ך עם מפרשים" היא אלפי מזהים.
      final ids = List.generate(5000, (i) => i + 1);
      KeepSet.install(db, ids);
      expect(KeepSet.count(db), 5000);

      // ושהתת-שאילתה אכן משמשת כתנאי סינון בפועל, לא רק נספרת.
      db.execute('CREATE TABLE book (id INTEGER PRIMARY KEY)');
      for (var i = 4990; i <= 5010; i++) {
        db.execute('INSERT INTO book VALUES ($i)');
      }
      final kept = db
          .select(
            'SELECT COUNT(*) c FROM book WHERE id IN (${KeepSet.selectIds})',
          )
          .first['c'];
      expect(kept, 11, reason: '4990..5000 בפנים, 5001..5010 בחוץ');
    });

    test('drop מסיר את הטבלה', () {
      KeepSet.install(db, {1});
      KeepSet.drop(db);
      expect(
        db
            .select("SELECT COUNT(*) c FROM temp.sqlite_master "
                "WHERE type='table' AND name='_keep'")
            .first['c'],
        0,
      );
    });

    test('drop על טבלה שאינה קיימת אינו זורק', () {
      expect(() => KeepSet.drop(db), returnsNormally);
      expect(() => KeepSet.drop(db), returnsNormally);
    });

    test('התקנה אחרי drop בונה את הטבלה מחדש', () {
      KeepSet.install(db, {1, 2});
      KeepSet.drop(db);
      KeepSet.install(db, {9});
      expect(KeepSet.count(db), 1);
    });

    test('הטבלה יושבת ב-temp ולא בסכמת main', () {
      // אם היא הייתה ב-main היא הייתה נכתבת לקובץ התוצאה ונשארת שם.
      KeepSet.install(db, {1});
      expect(
        db
            .select("SELECT COUNT(*) c FROM main.sqlite_master "
                "WHERE name='_keep'")
            .first['c'],
        0,
      );
    });
  });
}

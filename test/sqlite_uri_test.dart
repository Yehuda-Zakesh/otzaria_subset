import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';

/// בדיקות ל-URI של SQLite (`readOnlyUri`, `immutableUri`).
///
/// הנתיב האמיתי כאן תמיד עובר דרך תיקיית המשתמש בווינדוס — רווחים
/// (`Program Files`, שם משתמש עם רווח) ותווים בעברית הם המקרה הרגיל, לא
/// חריג. אם הקידוד לא שורד אותם, `ATTACH` נכשל בשקט או פותח קובץ אחר.
void main() {
  group('readOnlyUri', () {
    test('נתיב עם רווחים מקודד ומתפענח בחזרה לאותו נתיב', () {
      const path = r'C:\Users\Zeev Levental\Documents\seforim.db';
      final uri = readOnlyUri(path);

      expect(uri, endsWith('?mode=ro'));
      expect(uri, contains('%20'), reason: 'רווח בנתיב חייב לעבור קידוד');
      final withoutQuery = uri.substring(0, uri.length - '?mode=ro'.length);
      expect(Uri.parse(withoutQuery).toFilePath(windows: true), path);
    });

    test('נתיב עם תווים בעברית מקודד ב-UTF-8 ומתפענח בחזרה לאותו נתיב', () {
      const path = r'C:\Users\test\ספרים\שלום.db';
      final uri = readOnlyUri(path);

      expect(uri, endsWith('?mode=ro'));
      expect(uri, isNot(contains('שלום')),
          reason: 'תווים לא-ASCII חייבים לעבור קידוד אחוזים ולא להישאר '
              'כמות שהם ב-URI');
      final withoutQuery = uri.substring(0, uri.length - '?mode=ro'.length);
      expect(Uri.parse(withoutQuery).toFilePath(windows: true), path);
    });

    test('אות כונן נשמרת בפורמט file:///C:/... ולא נבלעת בקידוד', () {
      final uri = readOnlyUri(r'C:\Users\test\seforim.db');
      expect(uri, startsWith('file:///C:/'));
    });

    test('מוסיף בדיוק סיומת שאילתה אחת, בלי לשכפל', () {
      final uri = readOnlyUri(r'D:\data\seforim.db');
      expect('mode=ro'.allMatches(uri).length, 1);
      expect(uri.split('?').length, 2, reason: 'סימן שאלה אחד בדיוק');
    });
  });

  group('immutableUri', () {
    test('נתיב עם רווחים מקודד ומתפענח בחזרה לאותו נתיב', () {
      const path = r'C:\Program Files\Otzaria\seforim.db';
      final uri = immutableUri(path);

      expect(uri, endsWith('?immutable=1'));
      expect(uri, contains('%20'));
      final withoutQuery = uri.substring(0, uri.length - '?immutable=1'.length);
      expect(Uri.parse(withoutQuery).toFilePath(windows: true), path);
    });

    test('נתיב עם תיקיות בעברית ואות כונן מתפענח בחזרה לאותו נתיב', () {
      const path = r'C:\אוצריא\ספרים\seforim.db';
      final uri = immutableUri(path);

      expect(uri, startsWith('file:///C:/'));
      final withoutQuery = uri.substring(0, uri.length - '?immutable=1'.length);
      expect(Uri.parse(withoutQuery).toFilePath(windows: true), path);
    });

    test('מוסיף בדיוק סיומת שאילתה אחת, בלי לשכפל', () {
      final uri = immutableUri(r'D:\data\seforim.db');
      expect('immutable=1'.allMatches(uri).length, 1);
      expect(uri.split('?').length, 2);
    });
  });

  test('readOnlyUri ו-immutableUri חלוקים באותו בסיס, רק הסיומת שונה', () {
    // שני ה-URIs חייבים להצביע לאותו קובץ בדיוק — ההבדל היחיד הוא ההרשאה
    // שהם מבקשים מ-SQLite.
    const path = r'C:\x\seforim.db';
    final ro = readOnlyUri(path);
    final immutable = immutableUri(path);
    final roBase = ro.substring(0, ro.length - '?mode=ro'.length);
    final immutableBase =
        immutable.substring(0, immutable.length - '?immutable=1'.length);
    expect(roBase, immutableBase);
  });
}

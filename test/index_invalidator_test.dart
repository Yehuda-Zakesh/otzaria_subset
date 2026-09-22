import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:path/path.dart' as p;

import 'fixtures.dart';

/// בדיקות ביטול אינדקס החיפוש.
///
/// הנושא המרכזי כאן הוא **מה לא נמחק**. הפונקציה מוחקת תיקייה רקורסיבית
/// לפי נתיב שמגיע מקובץ הגדרות שהמשתמש יכול לערוך, ולכן השער שמזהה
/// "זו באמת תיקיית אינדקס" הוא החלק שחייב להיות נעול בבדיקות.
void main() {
  late Directory dir;

  setUp(() => dir = createTempDir('index'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String at(String name) => p.join(dir.path, name);

  /// יוצרת תיקייה עם קובץ אחד בשם [marker].
  String makeDir(String name, {String? marker, int bytes = 10}) {
    final d = Directory(at(name))..createSync(recursive: true);
    if (marker != null) {
      File(p.join(d.path, marker)).writeAsStringSync('x' * bytes);
    }
    return d.path;
  }

  const inv = OtzariaIndexInvalidator();

  group('resolveIndexDir', () {
    test('נתיב מוגדר גובר', () {
      expect(
        OtzariaIndexInvalidator.resolveIndexDir(
          libraryPath: r'C:\lib\seforim.db',
          configuredIndexPath: r'D:\my-index',
        ),
        r'D:\my-index',
      );
    });

    test('בלי נתיב מוגדר — אחות של תיקיית הספרייה, לא בתוכה', () {
      // אוצריא מחשבת את זה כך ב-AppPaths.getIndexPath; נתיב בתוך תיקיית
      // הספרייה היה נמחק יחד איתה בהתקנה מחדש.
      final resolved = OtzariaIndexInvalidator.resolveIndexDir(
        libraryPath: p.join('root', 'books', 'seforim.db'),
      );
      expect(resolved, p.join('root', 'books', 'index'));
    });

    test('נתיב מוגדר ריק נופל לברירת המחדל', () {
      final resolved = OtzariaIndexInvalidator.resolveIndexDir(
        libraryPath: p.join('root', 'books', 'seforim.db'),
        configuredIndexPath: '   ',
      );
      expect(resolved, p.join('root', 'books', 'index'));
    });
  });

  group('looksLikeIndex', () {
    test('תיקייה שאינה קיימת', () {
      expect(inv.looksLikeIndex(at('nope')), isFalse);
    });

    test('תיקייה ריקה', () {
      expect(inv.looksLikeIndex(makeDir('empty')), isFalse);
    });

    test('תיקייה עם קבצים לא קשורים', () {
      expect(inv.looksLikeIndex(makeDir('docs', marker: 'readme.txt')),
          isFalse);
    });

    for (final marker in OtzariaIndexInvalidator.indexMarkers) {
      test('מזוהה לפי $marker', () {
        expect(inv.looksLikeIndex(makeDir('idx-$marker', marker: marker)),
            isTrue);
      });
    }

    for (final ext in const ['.idx', '.term', '.store']) {
      test('מזוהה לפי סיומת segment של Tantivy: $ext', () {
        // אינדקס שה-meta שלו נמחק הוא עדיין אינדקס.
        expect(
          inv.looksLikeIndex(makeDir('seg$ext', marker: 'abc123$ext')),
          isTrue,
        );
      });
    }
  });

  group('isPrebuilt', () {
    test('מזוהה לפי הסמן של ה-installer', () {
      final d = makeDir('pre', marker: 'meta.json');
      expect(inv.isPrebuilt(d), isFalse);
      File(p.join(d, OtzariaIndexInvalidator.prebuiltMarker))
          .writeAsStringSync('');
      expect(inv.isPrebuilt(d), isTrue);
    });
  });

  group('invalidate', () {
    test('תיקייה שאינה קיימת אינה שגיאה', () {
      final r = inv.invalidate(at('nope'));
      expect(r.filesDeleted, 0);
      expect(r.bytesFreed, 0);
    });

    test('תיקייה שאינה נראית כאינדקס — זריקה, והיא נשארת', () {
      // זו ההגנה המרכזית: הנתיב מגיע מהגדרה שהמשתמש עורך, ומחיקה
      // רקורסיבית של מה שהוא מצביע אליו בלי בדיקה אינה הפיכה.
      final d = makeDir('mydocs', marker: 'important.txt');
      expect(
        () => inv.invalidate(d),
        throwsA(isA<IndexInvalidationException>()),
      );
      expect(Directory(d).existsSync(), isTrue);
      expect(File(p.join(d, 'important.txt')).existsSync(), isTrue);
    });

    test('אינדקס תקין נמחק ומדווח', () {
      final d = makeDir('idx', marker: 'meta.json', bytes: 100);
      File(p.join(d, 'seg.idx')).writeAsStringSync('y' * 50);
      final r = inv.invalidate(d);
      expect(r.filesDeleted, 2);
      expect(r.bytesFreed, 150);
      expect(r.dryRun, isFalse);
      expect(Directory(d).existsSync(), isFalse);
    });

    test('dryRun מדווח אבל אינו מוחק', () {
      final d = makeDir('idx', marker: 'meta.json', bytes: 100);
      final r = inv.invalidate(d, dryRun: true);
      expect(r.filesDeleted, 1);
      expect(r.bytesFreed, 100);
      expect(r.dryRun, isTrue);
      expect(Directory(d).existsSync(), isTrue,
          reason: 'dryRun הוא מה שה-UI מציג לפני שהמשתמש מאשר');
    });

    test('תת-תיקיות נספרות ונמחקות', () {
      final d = makeDir('idx', marker: 'meta.json', bytes: 10);
      final sub = Directory(p.join(d, 'segments'))..createSync();
      File(p.join(sub.path, 'a.store')).writeAsStringSync('z' * 20);
      File(p.join(sub.path, 'b.term')).writeAsStringSync('z' * 30);

      final r = inv.invalidate(d);
      expect(r.filesDeleted, 3);
      expect(r.bytesFreed, 60);
      expect(Directory(d).existsSync(), isFalse);
    });
  });
}

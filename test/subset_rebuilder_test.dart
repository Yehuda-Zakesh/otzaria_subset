import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'fixtures.dart';

/// בדיקות ל-[SubsetRebuilder] — בנייה מחדש ממסד מלא (שינוי סכמה, או ספר
/// שנכנס לבחירה מאוחר) וגיזום מיידי חזרה לבחירת המשתמש.
///
/// כמו ב-updater, הנושא המרכזי אינו "האם זה בונה" — לזה יש את
/// `subset_builder_test.dart` — אלא **מה קורה כשה-swap נכשל**: הספרייה
/// הקיימת של המשתמש חייבת להישאר שלמה, וכישלון ברכיב חיצוני ולא-קריטי
/// (ביטול אינדקס) אסור לו להפיל בנייה שהצליחה.
void main() {
  late Directory dir;

  setUp(() => dir = createTempDir('rebuilder'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String at(String name) => p.join(dir.path, name);

  T on<T>(String path, T Function(sqlite3.Database db) body) {
    final db = sqlite3.sqlite3.open(path, mode: sqlite3.OpenMode.readOnly);
    try {
      return body(db);
    } finally {
      db.close();
    }
  }

  Set<Object?> colOf(sqlite3.Database db, String table, String column) =>
      db.select('SELECT "$column" FROM "$table"').map((r) => r[column]).toSet();

  /// קובצי ה-staging הזמניים שנשארו בתיקיית היעד — חייב להיות ריק תמיד,
  /// גם אחרי כשל.
  List<String> stagingLeftovers() => dir
      .listSync()
      .whereType<File>()
      .map((f) => p.basename(f.path))
      .where(
          (name) => name.startsWith('rebuild-') && name.endsWith('.staging.db'))
      .toList();

  group('מסלול מוצלח', () {
    test('בנייה מחדש מחליפה ספרייה חלקית קיימת בבחירה חדשה, לא מוסיפה לה', () {
      buildFullDb(at('full.db'));
      const SubsetBuilder().build(
        sourcePath: at('full.db'),
        targetPath: at('subset.db'),
        bookIds: {1, 2},
      );

      final result = const SubsetRebuilder().rebuild(
        fullDbPath: at('full.db'),
        targetPath: at('subset.db'),
        spec: const SubsetSpec(categoryIds: {11}),
        deleteFullDbWhenDone: false,
      );

      expect(result.bookIds, {3, 4});
      on(at('subset.db'), (db) {
        expect(colOf(db, 'book', 'id'), {3, 4},
            reason: 'הבחירה הישנה (1,2) הוחלפה, לא נשארה לצד החדשה');
      });
    });

    test('ההחלפה אטומית: אין קובץ .bak ואין staging שנשארים אחרי הצלחה', () {
      buildFullDb(at('full.db'));
      File(at('subset.db')).writeAsStringSync('ספרייה ישנה');

      const SubsetRebuilder().rebuild(
        fullDbPath: at('full.db'),
        targetPath: at('subset.db'),
        spec: const SubsetSpec(categoryIds: {10}),
        deleteFullDbWhenDone: false,
      );

      expect(File('${at('subset.db')}.bak').existsSync(), isFalse);
      expect(stagingLeftovers(), isEmpty);
      on(at('subset.db'), (db) {
        expect(colOf(db, 'book', 'id'), {1, 2});
      });
    });

    test('deleteFullDbWhenDone=true מוחק את המסד המלא בסיום', () {
      buildFullDb(at('full.db'));
      const SubsetRebuilder().rebuild(
        fullDbPath: at('full.db'),
        targetPath: at('subset.db'),
        spec: const SubsetSpec(categoryIds: {10}),
        deleteFullDbWhenDone: true,
      );
      expect(File(at('full.db')).existsSync(), isFalse);
    });

    test('deleteFullDbWhenDone=false משאיר את המסד המלא במקומו', () {
      // שימושי כשמייצרים כמה פרופילים מאותו מסד מלא ומוחקים פעם אחת בסוף.
      buildFullDb(at('full.db'));
      const SubsetRebuilder().rebuild(
        fullDbPath: at('full.db'),
        targetPath: at('subset.db'),
        spec: const SubsetSpec(categoryIds: {10}),
        deleteFullDbWhenDone: false,
      );
      expect(File(at('full.db')).existsSync(), isTrue);
    });

    test('כישלון בביטול אינדקס החיפוש אינו מפיל בנייה מחדש שהצליחה', () {
      buildFullDb(at('full.db'));
      final indexDir = at('index');
      Directory(indexDir).createSync();
      // תיקייה שקיימת אבל לא נראית כמו אינדקס: looksLikeIndex מחזיר
      // false, invalidate זורק — וזה בדיוק המקרה שאסור לו לעצור בנייה
      // שכבר הצליחה (ראו ההערה ב-rebuild על סדר הפעולות).
      File(p.join(indexDir, 'not_an_index.txt')).writeAsStringSync('x');

      final result = const SubsetRebuilder().rebuild(
        fullDbPath: at('full.db'),
        targetPath: at('subset.db'),
        spec: const SubsetSpec(categoryIds: {10}),
        deleteFullDbWhenDone: false,
        indexDir: indexDir,
      );

      expect(result.indexInvalidation, isNull);
      on(at('subset.db'), (db) {
        expect(colOf(db, 'book', 'id'), {1, 2});
      });
    });
  });

  group('כשלים', () {
    test('בחירה ריקה זורקת ולא בונה כלום', () {
      buildFullDb(at('full.db'));
      expect(
        () => const SubsetRebuilder().rebuild(
          fullDbPath: at('full.db'),
          targetPath: at('subset.db'),
          spec: SubsetSpec.empty,
        ),
        throwsA(isA<SubsetRebuildException>()),
      );
      expect(File(at('subset.db')).existsSync(), isFalse);
    });

    test('מסד בלי db_schema_version זורק', () {
      buildFullDb(at('full.db'));
      final db = sqlite3.sqlite3.open(at('full.db'));
      try {
        db.execute("DELETE FROM schema_meta WHERE key='db_schema_version'");
      } finally {
        db.close();
      }

      expect(
        () => const SubsetRebuilder().rebuild(
          fullDbPath: at('full.db'),
          targetPath: at('subset.db'),
          spec: const SubsetSpec(categoryIds: {10}),
        ),
        throwsA(isA<SubsetRebuildException>().having(
          (e) => e.message,
          'message',
          contains('db_schema_version'),
        )),
      );
      expect(File(at('subset.db')).existsSync(), isFalse,
          reason: 'כשל לפני ה-swap לא אמור ליצור יעד חלקי');
    });

    test('כשל באמצע ה-swap משחזר מה-.bak ומשאיר את הספרייה הישנה שלמה', () {
      buildFullDb(at('full.db'));
      File(at('subset.db')).writeAsStringSync('ספרייה ישנה');

      expect(
        () => const SubsetRebuilder().rebuild(
          fullDbPath: at('full.db'),
          targetPath: at('subset.db'),
          spec: const SubsetSpec(categoryIds: {10}),
          deleteFullDbWhenDone: false,
          onStage: (stage) {
            // מדמה כשל בהחלפה: מוחקים את קובץ ה-staging בדיוק לפני ה-
            // rename שאמור להזיז אותו אל היעד, אחרי שהוא כבר נבנה ואומת.
            if (stage != 'swap') return;
            for (final f in dir.listSync().whereType<File>()) {
              if (p.basename(f.path).startsWith('rebuild-') &&
                  f.path.endsWith('.staging.db')) {
                f.deleteSync();
              }
            }
          },
        ),
        throwsA(isA<SubsetRebuildException>()),
      );

      expect(File(at('subset.db')).readAsStringSync(), 'ספרייה ישנה',
          reason: 'כשל באמצע ה-swap חייב להשאיר את הספרייה הישנה כשהייתה');
      expect(File('${at('subset.db')}.bak').existsSync(), isFalse,
          reason: 'ה-.bak משוחזר בחזרה למקום היעד, לא נשאר לצדו');
    });
  });
}

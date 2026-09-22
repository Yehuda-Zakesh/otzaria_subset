import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:path/path.dart' as p;

/// בדיקות מאגר הפרופילים — הרשומה של "מה יש לכל מחשב".
///
/// המאגר יושב על כונן נייד שנשלף מהשקע, ולכן שני דברים כאן אינם נוחות
/// אלא נכונות: שמירה אטומית (אין JSON חתוך), וטעינה שקובץ פגום אחד אינו
/// מסתיר בה את שאר המחשבים.
void main() {
  late Directory dir;
  late ProfileStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('profile_store_test');
    store = ProfileStore(dir.path);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  File fileFor(String id) => File(p.join(dir.path, '$id.json'));

  List<String> filesInDir() => [
        for (final e in dir.listSync()) p.basename(e.path),
      ]..sort();

  group('create', () {
    test('מחזיר פרופיל ושומר אותו לדיסק', () {
      final profile = store.create('המחשב בבית');
      expect(profile.label, 'המחשב בבית');
      expect(profile.spec, SubsetSpec.empty);
      expect(profile.hasLibrary, isFalse);
      expect(fileFor(profile.id).existsSync(), isTrue);
      expect(store.load(profile.id)!.label, 'המחשב בבית');
    });

    test('שם התצוגה נחתך מרווחים', () {
      expect(store.create('  לפטופ  ').label, 'לפטופ');
    });

    test('אותו שם פעמיים מקבל מזהה שונה עם סיומת -2', () {
      // שני מחשבים יכולים לקבל מאותו משתמש את אותו שם; מזהה מתנגש היה
      // דורס את הרשומה של המחשב הראשון ומאבד את הבחירה שלו.
      final first = store.create('המחשב בבית');
      final second = store.create('המחשב בבית');
      expect(second.id, isNot(first.id));
      expect(second.id, '${first.id}-2');
      expect(first.label, second.label);
      expect(store.loadAll(), hasLength(2));
    });

    test('שם שלישי מקבל -3 ולא דורס את -2', () {
      final a = store.create('מחשב');
      final b = store.create('מחשב');
      final c = store.create('מחשב');
      expect([a.id, b.id, c.id], equals(['מחשב', 'מחשב-2', 'מחשב-3']));
      expect({a.id, b.id, c.id}, hasLength(3));
      for (final id in [a.id, b.id, c.id]) {
        expect(store.load(id), isNotNull);
      }
    });

    test('יוצר את התיקייה אם אינה קיימת', () {
      final nested = ProfileStore(p.join(dir.path, 'sub', 'profiles'));
      final profile = nested.create('חדש');
      expect(nested.load(profile.id), isNotNull);
    });
  });

  group('save ו-load', () {
    test('הלוך ושוב שומר כל שדה', () {
      // אובדן שדה כאן אינו נראה עד העדכון הבא, ואז הספרייה נבנית מחדש
      // מאפס במקום לקבל patch.
      final applied = DateTime.utc(2026, 3, 14, 9, 26, 53, 589, 793);
      final original = SubsetProfile(
        id: 'beit-midrash',
        label: 'לפטופ בית המדרש',
        spec: const SubsetSpec(
          categoryIds: {10, 22},
          includeBookIds: {101},
          excludeBookIds: {7},
        ),
        dbVersion: 48,
        schemaVersion: 5,
        subsetHash: 'subset:abc123',
        dbPath: r'D:\otzaria\seforim.db',
        lastAppliedAt: applied,
        severedLinkCount: 1234,
      );
      store.save(original);

      final loaded = store.load('beit-midrash')!;
      expect(loaded.id, original.id);
      expect(loaded.label, original.label);
      expect(loaded.spec, original.spec);
      expect(loaded.dbVersion, 48);
      expect(loaded.schemaVersion, 5);
      expect(loaded.subsetHash, 'subset:abc123');
      expect(loaded.dbPath, r'D:\otzaria\seforim.db');
      expect(
          loaded.lastAppliedAt!.toIso8601String(), applied.toIso8601String());
      expect(loaded.severedLinkCount, 1234);
      expect(loaded.hasLibrary, isTrue);
    });

    test('שדות אופציונליים ריקים חוזרים null', () {
      store.save(const SubsetProfile(id: 'bare', label: 'ריק'));
      final loaded = store.load('bare')!;
      expect(loaded.dbVersion, isNull);
      expect(loaded.schemaVersion, isNull);
      expect(loaded.subsetHash, isNull);
      expect(loaded.dbPath, isNull);
      expect(loaded.lastAppliedAt, isNull);
      expect(loaded.severedLinkCount, 0);
      expect(loaded.spec, SubsetSpec.empty);
      expect(loaded.hasLibrary, isFalse);
    });

    test('שמירה חוזרת דורסת ולא מכפילה', () {
      store.save(const SubsetProfile(id: 'x', label: 'א', dbVersion: 1));
      store.save(const SubsetProfile(id: 'x', label: 'א', dbVersion: 2));
      expect(store.load('x')!.dbVersion, 2);
      expect(store.loadAll(), hasLength(1));
    });

    test('load של מזהה שאינו קיים מחזיר null', () {
      expect(store.load('no-such-profile'), isNull);
    });

    test('load של קובץ פגום מחזיר null ולא זורק', () {
      fileFor('broken').writeAsStringSync('{ not json');
      expect(store.load('broken'), isNull);
    });

    test('load של שורש שאינו אובייקט מחזיר null', () {
      fileFor('arr').writeAsStringSync('[1,2,3]');
      expect(store.load('arr'), isNull);
    });
  });

  group('שמירה אטומית', () {
    test('אין קובץ .tmp אחרי שמירה מוצלחת', () {
      // ‏.tmp שנשאר הוא שאריות של כתיבה שלא הושלמה; אחרי rename מוצלח
      // אסור שיישאר, אחרת אי אפשר להבחין בין הצלחה לכשל.
      store.save(const SubsetProfile(id: 'atomic', label: 'א'));
      expect(filesInDir(), equals(['atomic.json']));
      expect(filesInDir().where((f) => f.endsWith('.tmp')), isEmpty);
    });

    test('גם אחרי דריסה לא נשאר .tmp', () {
      store.save(const SubsetProfile(id: 'atomic', label: 'א'));
      store.save(const SubsetProfile(id: 'atomic', label: 'ב'));
      expect(filesInDir(), equals(['atomic.json']));
    });

    test('הקובץ שנכתב הוא JSON תקין וקריא', () {
      store.save(const SubsetProfile(
        id: 'readable',
        label: 'קריא',
        spec: SubsetSpec(categoryIds: {3, 1}),
      ));
      final raw = jsonDecode(fileFor('readable').readAsStringSync());
      expect(raw, isA<Map<String, dynamic>>());
      final map = raw as Map<String, dynamic>;
      expect(map['id'], 'readable');
      expect(
          (map['spec'] as Map<String, dynamic>)['categoryIds'], equals([1, 3]));
    });
  });

  group('loadAll', () {
    test('מחזיר את כל הפרופילים ממוינים לפי שם תצוגה', () {
      store.save(const SubsetProfile(id: 'c', label: 'גימל'));
      store.save(const SubsetProfile(id: 'a', label: 'אלף'));
      store.save(const SubsetProfile(id: 'b', label: 'בית'));
      expect([for (final x in store.loadAll()) x.label],
          equals(['אלף', 'בית', 'גימל']));
    });

    test('מתעלם מקבצים שאינם json', () {
      store.save(const SubsetProfile(id: 'real', label: 'אמיתי'));
      File(p.join(dir.path, 'notes.txt')).writeAsStringSync('hello');
      File(p.join(dir.path, 'seforim.db.tmp')).writeAsStringSync('xx');
      File(p.join(dir.path, 'profile.json.bak')).writeAsStringSync('{}');
      final loaded = store.loadAll();
      expect(loaded, hasLength(1));
      expect(loaded.single.id, 'real');
    });

    test('מתעלם מתיקיות משנה', () {
      store.save(const SubsetProfile(id: 'real', label: 'אמיתי'));
      Directory(p.join(dir.path, 'nested.json')).createSync();
      expect(store.loadAll(), hasLength(1));
    });

    test('תיקייה שאינה קיימת מחזירה רשימה ריקה', () {
      final missing = ProfileStore(p.join(dir.path, 'nope'));
      expect(missing.loadAll(), isEmpty);
    });

    test('קובץ פגום אינו מסתיר את שאר המחשבים', () {
      // זה הכשל שהיה הכי יקר: פרופיל אחד שנשבר בשליפת הכונן היה מוחק
      // מהמסך את כל המחשבים האחרים שרשומים עליו.
      store.save(const SubsetProfile(id: 'good1', label: 'אלף'));
      store.save(const SubsetProfile(id: 'good2', label: 'בית'));
      final corruptPath = p.join(dir.path, 'corrupt.json');
      File(corruptPath).writeAsStringSync('{ "id": "x", ');

      final reported = <String>[];
      final loaded = store.loadAll(
        onCorrupt: (path, error) => reported.add(path),
      );

      expect([for (final x in loaded) x.id], equals(['good1', 'good2']));
      expect(reported, equals([corruptPath]));
    });

    test('onCorrupt מדווח גם על פרופיל בלי מזהה ועל שורש שאינו אובייקט', () {
      store.save(const SubsetProfile(id: 'good', label: 'טוב'));
      File(p.join(dir.path, 'no-id.json'))
          .writeAsStringSync(jsonEncode({'label': 'בלי מזהה'}));
      File(p.join(dir.path, 'list.json')).writeAsStringSync('[]');

      final reported = <String>[];
      final errors = <Object>[];
      final loaded = store.loadAll(onCorrupt: (path, error) {
        reported.add(p.basename(path));
        errors.add(error);
      });

      expect(loaded.single.id, 'good');
      expect(reported..sort(), equals(['list.json', 'no-id.json']));
      expect(errors, everyElement(isA<FormatException>()));
    });

    test('קובץ פגום בלי onCorrupt אינו זורק', () {
      store.save(const SubsetProfile(id: 'good', label: 'טוב'));
      File(p.join(dir.path, 'bad.json')).writeAsStringSync('nonsense');
      expect(store.loadAll().single.id, 'good');
    });
  });

  group('delete', () {
    test('מחזיר true ואז false בקריאה שנייה', () {
      // הקריאה השנייה היא מה שמבדיל בין "נמחק" ל"לא היה" — ה-UI מציג
      // הודעה אחרת לכל אחד מהם.
      final profile = store.create('למחיקה');
      expect(store.delete(profile.id), isTrue);
      expect(store.delete(profile.id), isFalse);
      expect(store.load(profile.id), isNull);
      expect(store.loadAll(), isEmpty);
    });

    test('מחיקת מזהה שאינו קיים מחזירה false', () {
      expect(store.delete('ghost'), isFalse);
    });

    test('מחיקה אינה נוגעת בשאר הפרופילים', () {
      store.save(const SubsetProfile(id: 'a', label: 'אלף'));
      store.save(const SubsetProfile(id: 'b', label: 'בית'));
      expect(store.delete('a'), isTrue);
      expect(store.loadAll().single.id, 'b');
    });
  });

  group('isWritable', () {
    test('אמת בתיקייה זמנית רגילה', () {
      expect(store.isWritable, isTrue);
    });

    test('יוצר תיקייה שאינה קיימת ואינו משאיר קובץ בדיקה', () {
      // בדיקת הכתיבה רצה לפני שמציעים למשתמש לשמור; קובץ בדיקה
      // שנשאר היה מופיע כזבל על הכונן שלו.
      final nested = ProfileStore(p.join(dir.path, 'probe-dir'));
      expect(nested.isWritable, isTrue);
      expect(nested.directory.listSync(), isEmpty);
    });
  });

  group('SubsetProfile.slugify', () {
    test('שם עברי נשמר כמות שהוא', () {
      // המזהה הוא שם קובץ, אבל הרוב המכריע של השמות כאן בעברית —
      // תעתיק ל-ASCII היה הופך כל פרופיל ל-"profile".
      expect(SubsetProfile.slugify('מחשב'), 'מחשב');
      expect(SubsetProfile.slugify('המחשב בבית'), 'המחשב-בבית');
    });

    test('תווים מסוכנים בנתיב הופכים למקף', () {
      expect(SubsetProfile.slugify(r'a\b'), 'a-b');
      expect(SubsetProfile.slugify('a/b'), 'a-b');
      expect(SubsetProfile.slugify('C:name'), 'C-name');
      expect(SubsetProfile.slugify('a*b'), 'a-b');
      expect(SubsetProfile.slugify('a?b'), 'a-b');
      expect(SubsetProfile.slugify('a"b'), 'a-b');
      expect(SubsetProfile.slugify('a<b'), 'a-b');
      expect(SubsetProfile.slugify('a>b'), 'a-b');
      expect(SubsetProfile.slugify('a|b'), 'a-b');
    });

    test('כל סוגי הרווח הופכים למקף', () {
      expect(SubsetProfile.slugify('a b'), 'a-b');
      expect(SubsetProfile.slugify('a\tb'), 'a-b');
      expect(SubsetProfile.slugify('a\nb'), 'a-b');
    });

    test('רצף תווים מסוכנים מתכנס למקף אחד', () {
      expect(SubsetProfile.slugify('a   b'), 'a-b');
      expect(SubsetProfile.slugify(r'a /\: b'), 'a-b');
    });

    test('מקפים כפולים שהמשתמש כתב מתכנסים גם הם', () {
      expect(SubsetProfile.slugify('a--b'), 'a-b');
      expect(SubsetProfile.slugify('a - b'), 'a-b');
    });

    test('מקף בקצוות נחתך', () {
      expect(SubsetProfile.slugify('-abc-'), 'abc');
      expect(SubsetProfile.slugify('  מחשב  '), 'מחשב');
      expect(SubsetProfile.slugify('/abc/'), 'abc');
    });

    test('קלט ריק או חסר תוכן נותן profile', () {
      // מזהה ריק היה מייצר את הקובץ ".json" ומאבד את הפרופיל.
      expect(SubsetProfile.slugify(''), 'profile');
      expect(SubsetProfile.slugify('   '), 'profile');
      expect(SubsetProfile.slugify('///'), 'profile');
      expect(SubsetProfile.slugify('-'), 'profile');
    });

    test('התוצאה תמיד בטוחה כשם קובץ', () {
      const labels = ['המחשב בבית', r'a\b/c:d*e?f"g<h>i|j', '  ', '--'];
      for (final label in labels) {
        final slug = SubsetProfile.slugify(label);
        expect(slug, isNotEmpty, reason: label);
        expect(slug, isNot(matches(RegExp(r'[\\/:*?"<>|\s]'))), reason: label);
        expect(p.basename('$slug.json'), '$slug.json', reason: label);
      }
    });
  });
}

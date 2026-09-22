import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:path/path.dart' as p;

import 'fixtures.dart';

/// בדיקות זיהוי המחשב והרישום שמקשר מחשב לפרופיל.
///
/// המשתמש אינו בוחר מחשב מרשימה — התוכנה מזהה לבד. לכן שתי תכונות כאן
/// הן קריטיות ולא נוחות: המזהה **מתמיד** בין הרצות, והרישום **שורד**
/// מחיקה של המזהה (דרך שם המחשב). כשל באחת מהן מייצר פרופיל כפול,
/// כלומר בנייה מחדש של ספרייה שכבר קיימת.
void main() {
  late Directory dir;

  setUp(() => dir = createTempDir('machine'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String at(String name) => p.join(dir.path, name);

  MachineIdentity identity(String id, {String hostname = 'PC-1'}) =>
      MachineIdentity(id: id, hostname: hostname, platform: 'windows');

  group('MachineIdentity.resolve', () {
    test('יוצר קובץ ומחזיר מזהה הקסדצימלי', () {
      final m = MachineIdentity.resolve(stateDir: at('state'));
      expect(m.id, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(
        File(p.join(at('state'), MachineIdentity.fileName)).existsSync(),
        isTrue,
      );
    });

    test('קריאה שנייה מחזירה את אותו מזהה', () {
      // זו כל הנקודה: בלי התמדה כל הרצה הייתה נראית כמחשב חדש.
      final first = MachineIdentity.resolve(stateDir: at('state'));
      final second = MachineIdentity.resolve(stateDir: at('state'));
      expect(second.id, first.id);
    });

    test('תיקיות מצב שונות — מזהים שונים', () {
      final a = MachineIdentity.resolve(stateDir: at('a'));
      final b = MachineIdentity.resolve(stateDir: at('b'));
      expect(a.id, isNot(b.id));
    });

    test('קובץ ריק מוחלף במזהה חדש ולא מוחזר כמו שהוא', () {
      final stateDir = Directory(at('state'))..createSync(recursive: true);
      File(p.join(stateDir.path, MachineIdentity.fileName))
          .writeAsStringSync('   \n  ');
      final m = MachineIdentity.resolve(stateDir: stateDir.path);
      expect(m.id, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('שם המחשב והפלטפורמה מאוכלסים', () {
      final m = MachineIdentity.resolve(stateDir: at('state'));
      expect(m.hostname, isNotNull);
      expect(
        m.platform,
        anyOf('windows', 'macos', 'linux', Platform.operatingSystem),
      );
    });

    test('תיקיית מצב שלא ניתן ליצור — זהות חולפת, בלי זריקה', () {
      // מחשב נעול לכתיבה עדיין צריך לעבוד; ההתאמה תיפול על שם המחשב.
      final blocker = File(at('blocker'))..writeAsStringSync('x');
      final m = MachineIdentity.resolve(
        stateDir: p.join(blocker.path, 'state'),
      );
      expect(m.id, startsWith('host:'));
    });
  });

  group('suggestedLabel', () {
    test('שם מחשב קיים מוחזר כמו שהוא', () {
      expect(identity('x', hostname: 'לפטופ').suggestedLabel, 'לפטופ');
    });

    test('שם מחשב ריק נופל לברירת מחדל', () {
      expect(identity('x', hostname: '').suggestedLabel, 'מחשב זה');
    });
  });

  group('defaultStateDir', () {
    test('נתיב לא ריק', () {
      final path = MachineIdentity.defaultStateDir();
      expect(path, isNotEmpty);
      if (Platform.isWindows) {
        expect(path, contains('OtzariaSubset'));
      }
    });
  });

  group('MachineRegistry', () {
    test('תיקייה נקייה — אין שיוך', () {
      final reg = MachineRegistry(at('profiles'));
      expect(reg.profileIdFor(identity('aaa')), isNull);
    });

    test('bind ואז profileIdFor', () {
      final reg = MachineRegistry(at('profiles'));
      reg.bind(identity('aaa'), 'pc-bait');
      expect(reg.profileIdFor(identity('aaa')), 'pc-bait');
    });

    test('bind חוזר דורס ואינו מכפיל', () {
      final reg = MachineRegistry(at('profiles'));
      reg.bind(identity('aaa'), 'first');
      reg.bind(identity('aaa'), 'second');
      expect(reg.profileIdFor(identity('aaa')), 'second');
      expect(reg.allBindings().length, 1);
    });

    test('שני מחשבים נשמרים בנפרד', () {
      final reg = MachineRegistry(at('profiles'));
      reg.bind(identity('aaa', hostname: 'PC-1'), 'one');
      reg.bind(identity('bbb', hostname: 'PC-2'), 'two');
      expect(reg.profileIdFor(identity('aaa', hostname: 'PC-1')), 'one');
      expect(reg.profileIdFor(identity('bbb', hostname: 'PC-2')), 'two');
      expect(reg.allBindings().length, 2);
    });

    test('unbind מסיר רק את השיוך שלו', () {
      final reg = MachineRegistry(at('profiles'));
      reg.bind(identity('aaa', hostname: 'PC-1'), 'one');
      reg.bind(identity('bbb', hostname: 'PC-2'), 'two');
      reg.unbind(identity('aaa', hostname: 'PC-1'));
      expect(reg.profileIdFor(identity('aaa', hostname: 'PC-9')), isNull);
      expect(reg.profileIdFor(identity('bbb', hostname: 'PC-2')), 'two');
    });

    test('נפילה לשם המחשב כשהמזהה המתמיד נמחק', () {
      // מסלול ההתאוששות: %LOCALAPPDATA% נוקה, ה-GUID אבד. בלי הנפילה
      // הזו נוצר פרופיל כפול והמשתמש בונה מחדש ספרייה שכבר יש לו.
      final reg = MachineRegistry(at('profiles'));
      reg.bind(identity('aaa', hostname: 'PC-1'), 'pc-bait');
      expect(reg.profileIdFor(identity('bbb', hostname: 'PC-1')), 'pc-bait');
    });

    test('שם מחשב ריק אינו מייצר התאמה', () {
      // שני מחשבים ששמם אינו ידוע אינם אותו מחשב.
      final reg = MachineRegistry(at('profiles'));
      reg.bind(identity('aaa', hostname: ''), 'one');
      expect(reg.profileIdFor(identity('bbb', hostname: '')), isNull);
    });

    test('רישום פגום אינו זורק ואינו חוסם bind', () {
      final d = Directory(at('profiles'))..createSync(recursive: true);
      File(p.join(d.path, MachineRegistry.fileName))
          .writeAsStringSync('{ this is not json');
      final reg = MachineRegistry(d.path);
      expect(reg.profileIdFor(identity('aaa')), isNull);
      reg.bind(identity('aaa'), 'recovered');
      expect(reg.profileIdFor(identity('aaa')), 'recovered');
    });

    test('bind אינו משאיר קובץ .tmp', () {
      final reg = MachineRegistry(at('profiles'));
      reg.bind(identity('aaa'), 'one');
      final leftovers = Directory(at('profiles'))
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    });

    test('ProfileStore מתעלם מקובץ הרישום באותה תיקייה', () {
      // הרישום אינו .json במכוון: ProfileStore קורא כל *.json כפרופיל,
      // וקובץ רישום שהיה נקרא שם היה מדווח כפרופיל פגום בכל טעינה.
      final store = ProfileStore(at('profiles'));
      final created = store.create('המחשב בבית');
      MachineRegistry(at('profiles')).bind(identity('aaa'), created.id);

      final corrupt = <String>[];
      final profiles = store.loadAll(onCorrupt: (path, _) => corrupt.add(path));
      expect(corrupt, isEmpty);
      expect(profiles.map((p) => p.id), [created.id]);
    });
  });
}

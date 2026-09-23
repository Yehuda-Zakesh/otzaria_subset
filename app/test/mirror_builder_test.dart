import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otzaria_subset_app/services/mirror_builder.dart';
import 'package:otzaria_subset_app/widgets/format.dart';
import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/seforim_library_updater.dart';

/// הבדיקות רצות מול GitHub מדומה: רשימת releases, מניפסטים ונכסים זעירים.
/// אין כאן רשת ואין תוכן ספרים — רק מבנה ההפצה, שהוא מה שנבדק.

Map<String, dynamic> _manifest(int from, int to) => {
      'fromVersion': from,
      'toVersion': to,
      'fromSchemaVersion': 2,
      'toSchemaVersion': 2,
      'fromContentHash': 'h$from',
      'toContentHash': 'h$to',
      'patchFiles': [
        {
          'file': 'patch-v$from-v$to.db.zst',
          'compression': 'zstd',
          'sha256': 'unused',
          'size': 1,
          'uncompressedSha256': 'u',
          'uncompressedSize': 9,
        },
      ],
    };

class _FakeGithub {
  /// tag → שמות הנכסים שבו.
  final Map<String, List<String>> releases;

  /// כל נכס (לא API) שהתבקש, לפי הסדר.
  final List<String> fetched = [];

  /// כשמוגדר — כל בקשה נכשלת כאילו אין רשת.
  bool offline = false;

  _FakeGithub(this.releases);

  Uint8List _body(String name) {
    final match = RegExp(r'^patch-v(\d+)-v(\d+)\.db\.zst\.manifest\.json$')
        .firstMatch(name);
    if (match != null) {
      return Uint8List.fromList(utf8.encode(jsonEncode(_manifest(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
      ))));
    }
    return Uint8List.fromList(utf8.encode('asset:$name'));
  }

  http.Client get client => MockClient.streaming((request, _) async {
        if (offline) throw http.ClientException('no network', request.url);
        final url = request.url.toString();
        Uint8List body;
        if (url.contains('api.github.com')) {
          final page = request.url.queryParameters['page'];
          body = Uint8List.fromList(utf8.encode(jsonEncode([
            if (page == '1')
              for (final entry in releases.entries)
                {
                  'tag_name': entry.key,
                  'prerelease': false,
                  'draft': false,
                  'published_at': '2026-09-01T00:00:00Z',
                  'assets': [
                    for (final name in entry.value)
                      {
                        'name': name,
                        'browser_download_url': 'https://x/${entry.key}/$name',
                        'size': _body(name).length,
                        'id': name.hashCode.abs(),
                        'digest': 'sha256:${Sha256Stream.ofBytes(_body(name))}',
                      },
                  ],
                },
          ])));
        } else {
          final name = url.split('/').last;
          fetched.add(name);
          body = _body(name);
        }
        return http.StreamedResponse(
          Stream.value(body),
          200,
          contentLength: body.length,
        );
      });
}

/// שלוש גרסאות בשרשרת, וכל אחת נושאת גם ספרייה מלאה.
Map<String, List<String>> _chain() => {
      'v1': ['seforim.db.zst'],
      'v2': [
        'patch-v1-v2.db.zst.manifest.json',
        'patch-v1-v2.db.zst',
        'seforim.db.zst',
      ],
      'v3': [
        'patch-v2-v3.db.zst.manifest.json',
        'patch-v2-v3.db.zst',
        'seforim.db.zst',
      ],
    };

void main() {
  late Directory tmp;
  late String drive;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mirror_builder');
    drive = p.join(tmp.path, 'drive');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> saveStatus(int? version) => OfflineComputerStatus(
        libraryVersion: version,
        savedAt: DateTime(2026, 9, 20),
        computerName: 'PC',
      ).writeTo(drive);

  /// מה שהמחשב הלא־מקוון יראה בפועל — דרך הלקוח שהוא עצמו משתמש בו.
  Future<List<String>> mirroredAssets() async {
    final client = LocalMirrorLibraryReleaseClient(mirrorDir: drive);
    final releases = await client.fetchReleases();
    return [
      for (final r in releases)
        for (final a in r.assets) ...[
          a.name,
          if (!File(a.downloadUrl).existsSync()) 'MISSING:${a.name}',
        ],
    ];
  }

  group('מצב המחשב הלא־מקוון', () {
    test('נכתב ונקרא בחזרה', () async {
      await saveStatus(7);
      final status = await OfflineComputerStatus.readFrom(drive);
      expect(status?.libraryVersion, 7);
      expect(status?.computerName, 'PC');
      expect(File(p.join(drive, '${OfflineComputerStatus.fileName}.tmp')),
          isNot(predicate<File>((f) => f.existsSync())));
    });

    test('קובץ פגום או בפורמט אחר נחשב כאילו אינו קיים', () async {
      final file = File(p.join(drive, OfflineComputerStatus.fileName));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{{{');
      expect(await OfflineComputerStatus.readFrom(drive), isNull);
      file.writeAsStringSync(jsonEncode({
        'format': 99,
        'libraryVersion': 3,
        'savedAt': '2026-09-20T00:00:00Z',
      }));
      expect(await OfflineComputerStatus.readFrom(drive), isNull);
      expect(await OfflineComputerStatus.readFrom(tmp.path), isNull);
    });

    test('ספרייה שאינה קיימת נשמרת כגרסה לא ידועה', () {
      final status =
          OfflineComputerStatus.capture(p.join(tmp.path, 'missing.db'));
      expect(status.libraryVersion, isNull);
      expect(OfflineComputerStatus.capture(null).libraryVersion, isNull);
    });
  });

  group('הכנת הכונן', () {
    test('בלי מצב שמור: כל העדכונים, בלי הספרייה המלאה', () async {
      final gh = _FakeGithub(_chain());
      final result =
          await MirrorBuilder(httpClient: gh.client).build(destDir: drive);

      expect(result.upToDate, isFalse);
      expect(result.includesFullLibrary, isFalse);
      expect(result.coversOtherComputer, isNull);
      expect(gh.fetched.where((n) => n.startsWith('seforim.db.zst')), isEmpty);
      final assets = await mirroredAssets();
      expect(assets, containsAll(['patch-v1-v2.db.zst', 'patch-v2-v3.db.zst']));
      expect(assets.where((n) => n.startsWith('MISSING')), isEmpty);
    });

    test('ספרייה מלאה שפורסמה בחלקים אינה יורדת בלי מצב שמור', () async {
      final gh = _FakeGithub({
        'v2': [
          'patch-v1-v2.db.zst.manifest.json',
          'patch-v1-v2.db.zst',
          'seforim.db.zst.manifest.json',
          'seforim.db.zst.part-000',
          'seforim.db.zst.part-001',
        ],
      });
      await MirrorBuilder(httpClient: gh.client).build(destDir: drive);
      expect(gh.fetched.where((n) => n.startsWith('seforim.db.zst')), isEmpty);
      expect(await mirroredAssets(), contains('patch-v1-v2.db.zst'));
    });

    test('עם מצב שמור: רק מה שחסר מהגרסה שלו', () async {
      await saveStatus(2);
      final gh = _FakeGithub(_chain());
      final result =
          await MirrorBuilder(httpClient: gh.client).build(destDir: drive);

      expect(result.coversOtherComputer, isTrue);
      expect(result.includesFullLibrary, isFalse);
      expect(gh.fetched, isNot(contains('patch-v1-v2.db.zst')));
      expect(gh.fetched, isNot(contains('seforim.db.zst')));
      expect(await mirroredAssets(), contains('patch-v2-v3.db.zst'));
      // המצב נשאר על הכונן: הייצוא מנקה רק את תיקיית הנכסים.
      expect(await OfflineComputerStatus.readFrom(drive), isNotNull);
    });

    test('המחשב השני כבר מעודכן — שום דבר לא יורד', () async {
      await saveStatus(3);
      final gh = _FakeGithub(_chain());
      final result =
          await MirrorBuilder(httpClient: gh.client).build(destDir: drive);
      expect(result.upToDate, isTrue);
      expect(gh.fetched.where((n) => !n.endsWith('.manifest.json')), isEmpty);
    });

    test('עם ספרייה מלאה: הכונן מחזיק אותה', () async {
      await saveStatus(2);
      final gh = _FakeGithub(_chain());
      final result = await MirrorBuilder(httpClient: gh.client)
          .build(destDir: drive, includeFullLibrary: true);
      expect(result.includesFullLibrary, isTrue);
      expect(result.coversOtherComputer, isTrue);
      expect(await mirroredAssets(), contains('seforim.db.zst'));
    });

    test('מצב בלי גרסה ידועה מביא את הספרייה המלאה מעצמו', () async {
      await saveStatus(null);
      final gh = _FakeGithub(_chain());
      final result =
          await MirrorBuilder(httpClient: gh.client).build(destDir: drive);
      expect(result.includesFullLibrary, isTrue);
      expect(result.coversOtherComputer, isTrue);
    });

    test('שרשרת שנקטעה בלי ספרייה מלאה — מדווח שהכונן לא יספיק', () async {
      await saveStatus(1);
      final gh = _FakeGithub({
        'v3': ['patch-v2-v3.db.zst.manifest.json', 'patch-v2-v3.db.zst'],
      });
      final result =
          await MirrorBuilder(httpClient: gh.client).build(destDir: drive);
      expect(result.coversOtherComputer, isFalse);
    });

    test('הרצה חוזרת על אותו כונן אינה מורידה שוב', () async {
      final gh = _FakeGithub(_chain());
      final builder = MirrorBuilder(httpClient: gh.client);
      await builder.build(destDir: drive);
      gh.fetched.clear();
      await builder.build(destDir: drive);
      expect(gh.fetched.where((n) => !n.endsWith('.manifest.json')), isEmpty);
    });

    test('ביטול: הכונן אינו נראה מוכן', () async {
      final gh = _FakeGithub(_chain());
      await expectLater(
        MirrorBuilder(httpClient: gh.client)
            .build(destDir: drive, isCancelled: () => true),
        throwsA(isA<MirrorBuildCancelled>()),
      );
      expect(
        File(p.join(drive, LocalMirrorLibraryReleaseClient.manifestFileName))
            .existsSync(),
        isFalse,
      );
    });

    test('בלי רשת: הודעה שמותר להציג', () async {
      final gh = _FakeGithub(_chain())..offline = true;
      try {
        await MirrorBuilder(httpClient: gh.client).build(destDir: drive);
        fail('expected failure');
      } on MirrorBuildException catch (e) {
        expect(hasInternalTerms(e.message), isFalse);
        expect(e.message, contains('אינטרנט'));
      }
    });

    test('התקדמות מדווחת בבייטים ובקבצים', () async {
      final gh = _FakeGithub(_chain());
      final seen = <MirrorProgress>[];
      await MirrorBuilder(httpClient: gh.client)
          .build(destDir: drive, onProgress: seen.add);
      expect(seen.first.phase, MirrorPhase.preparing);
      final downloads = seen.where((s) => s.phase == MirrorPhase.downloading);
      expect(downloads, isNotEmpty);
      expect(downloads.last.totalFiles, greaterThan(0));
      expect(downloads.last.doneFiles, downloads.last.totalFiles);
    });
  });
}

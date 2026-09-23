import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otzaria_subset_app/services/app_updater.dart';
import 'package:path/path.dart' as p;

final List<int> _payload = utf8.encode('stub + payload + footer');
final String _payloadHash = sha256.convert(_payload).toString();

/// תשובת `releases/latest` בצורה שגיטהאב מחזיר.
Map<String, dynamic> _release({
  String tag = 'v1.2.4',
  Object? digest =
      'sha256:0c78454019a6f81078ba133b12ff0dae6c4d1834088e92e4e22796f2ae8f2fc0',
  String name = 'OtzariaSubset.exe',
}) =>
    {
      'tag_name': tag,
      'assets': [
        {
          'name': 'notes.txt',
          'browser_download_url': 'https://example.invalid/notes.txt',
          'size': 1,
          'digest': 'sha256:${'0' * 64}',
        },
        {
          'name': name,
          'browser_download_url': 'https://example.invalid/$name',
          'size': 9328956,
          'digest': digest,
        },
      ],
    };

void main() {
  group('parseDigest', () {
    test('מחלץ hex ומנרמל לאותיות קטנות', () {
      expect(parseDigest('sha256:${'AB' * 32}'), 'ab' * 32);
    });

    test('אלגוריתם אחר, אורך שגוי או ערך חסר → null', () {
      expect(parseDigest('sha512:${'a' * 64}'), isNull);
      expect(parseDigest('sha256:${'a' * 63}'), isNull);
      expect(parseDigest('sha256:${'g' * 64}'), isNull);
      expect(parseDigest(null), isNull);
      expect(parseDigest(42), isNull);
    });
  });

  group('parseRelease', () {
    test('בוחר את ה-exe הראשון ומעביר את ה-digest', () {
      final release = parseRelease(_release(), currentVersion: '1.2.3')!;
      expect(release.version, '1.2.4');
      expect(release.downloadUrl.path, '/OtzariaSubset.exe');
      expect(release.sizeBytes, 9328956);
      expect(release.sha256,
          '0c78454019a6f81078ba133b12ff0dae6c4d1834088e92e4e22796f2ae8f2fc0');
    });

    test('שם עם גרסה עדיין נבחר — הסיומת היא החוזה', () {
      final release = parseRelease(
        _release(name: 'otzaria-subset-1.2.4.exe'),
        currentVersion: '1.2.3',
      );
      expect(release, isNotNull);
    });

    test('digest חסר נשאר null ולא מפיל את הבדיקה', () {
      final release =
          parseRelease(_release(digest: null), currentVersion: '1.2.3');
      expect(release, isNotNull);
      expect(release!.sha256, isNull);
    });

    test('גרסה שאינה חדשה יותר → אין עדכון', () {
      expect(parseRelease(_release(), currentVersion: '1.2.4'), isNull);
      expect(parseRelease(_release(), currentVersion: '2.0.0'), isNull);
    });

    test('תשובה בפורמט לא מוכר → null', () {
      expect(parseRelease('oops', currentVersion: '1.2.3'), isNull);
      expect(
        parseRelease({'tag_name': 'v1.2.4'}, currentVersion: '1.2.3'),
        isNull,
      );
    });
  });

  group('install', () {
    late Directory dir;
    late File downloaded;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('app_updater_test');
      downloaded = File(p.join(dir.path, 'otzaria-subset-update.exe'));
    });

    tearDown(() => dir.deleteSync(recursive: true));

    AppRelease releaseWith(String? hash) => AppRelease(
          version: '1.2.4',
          downloadUrl: Uri.parse('https://example.invalid/OtzariaSubset.exe'),
          sizeBytes: _payload.length,
          sha256: hash,
        );

    var requests = 0;
    String? handedOff;

    AppUpdater updater() => AppUpdater(
          client: MockClient((_) async {
            requests++;
            return http.Response.bytes(_payload, 200);
          }),
          downloadDir: dir.path,
          handOff: (path) async => handedOff = path,
        );

    setUp(() {
      requests = 0;
      handedOff = null;
    });

    test('hash תואם → הקובץ נשמר ומועבר לפורש', () async {
      final progress =
          await updater().install(releaseWith(_payloadHash)).toList();
      expect(progress.last, 1);
      expect(handedOff, downloaded.path);
      expect(downloaded.readAsBytesSync(), _payload);
    });

    test('hash שאינו תואם → נזרק, הקובץ נמחק ואין העברה', () async {
      await expectLater(
        updater().install(releaseWith('f' * 64)).toList(),
        throwsA(isA<HttpException>()),
      );
      expect(handedOff, isNull);
      expect(downloaded.existsSync(), isFalse);
    });

    test('בלי digest → מסרבים עוד לפני ההורדה', () async {
      await expectLater(
        updater().install(releaseWith(null)).toList(),
        throwsA(isA<StateError>()),
      );
      expect(requests, 0);
      expect(handedOff, isNull);
    });

    test('שגיאת שרת → נזרק ואין העברה', () async {
      final failing = AppUpdater(
        client: MockClient((_) async => http.Response('', 404)),
        downloadDir: dir.path,
        handOff: (path) async => handedOff = path,
      );
      await expectLater(
        failing.install(releaseWith(_payloadHash)).toList(),
        throwsA(isA<HttpException>()),
      );
      expect(handedOff, isNull);
      expect(downloaded.existsSync(), isFalse);
    });
  });
}

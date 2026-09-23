import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';

/// בדיקות ל-[OtzariaUpdateGuard] — ההכרעה אם עדכון הספרייה האוטומטי של
/// אוצריא כבוי. אין כאן שום קריאת קובץ: המחלקה מקבלת ערכים גולמיים בלבד,
/// ולכן הבדיקות עצמן קלות ובלי fixtures.
void main() {
  const guard = OtzariaUpdateGuard();

  group('fromValues', () {
    test('כל אחד משלושת המפתחות נקרא true/false בנפרד', () {
      final offlineTrue = guard.fromValues(
        source: 's',
        values: {OtzariaUpdateGuard.keyOfflineMode: true},
      );
      expect(offlineTrue.offlineMode, isTrue);
      expect(offlineTrue.softwareAndBookUpdatesEnabled, isNull);
      expect(offlineTrue.autoSync, isNull);

      final offlineFalse = guard.fromValues(
        source: 's',
        values: {OtzariaUpdateGuard.keyOfflineMode: false},
      );
      expect(offlineFalse.offlineMode, isFalse);

      final swTrue = guard.fromValues(
        source: 's',
        values: {OtzariaUpdateGuard.keySoftwareAndBookUpdates: true},
      );
      expect(swTrue.softwareAndBookUpdatesEnabled, isTrue);

      final swFalse = guard.fromValues(
        source: 's',
        values: {OtzariaUpdateGuard.keySoftwareAndBookUpdates: false},
      );
      expect(swFalse.softwareAndBookUpdatesEnabled, isFalse);

      final autoTrue = guard.fromValues(
        source: 's',
        values: {OtzariaUpdateGuard.keyAutoSync: true},
      );
      expect(autoTrue.autoSync, isTrue);

      final autoFalse = guard.fromValues(
        source: 's',
        values: {OtzariaUpdateGuard.keyAutoSync: false},
      );
      expect(autoFalse.autoSync, isFalse);
    });

    test('found תמיד true כשהקריאה מהקופסה הצליחה, גם על ערכים ריקים', () {
      final s = guard.fromValues(source: 'x', values: const {});
      expect(s.found, isTrue);
      expect(s.source, 'x');
    });

    test('ערך שאינו bool תחת מפתח ידוע הופך ל-null ולא נחשב מידע', () {
      // אותו מפתח יכול לשאת טיפוס אחר אם נכתב פעם אחרת; "כבוי" שנגזר
      // מערך כזה הוא בדיוק הטעות המסוכנת שהמחלקה נמנעת ממנה.
      final s = guard.fromValues(
        source: 's',
        values: {
          OtzariaUpdateGuard.keyAutoSync: 'disabled',
          OtzariaUpdateGuard.keyOfflineMode: 1,
          OtzariaUpdateGuard.keySoftwareAndBookUpdates: null,
        },
      );
      expect(s.autoSync, isNull);
      expect(s.offlineMode, isNull);
      expect(s.softwareAndBookUpdatesEnabled, isNull);
    });
  });

  group('isDisabled — טבלת אמת מלאה', () {
    // כל שמונת השילובים של שלושת הדגלים (found=true בכל מקרה).
    const cases = [
      [true, true, true],
      [true, true, false],
      [true, false, true],
      [true, false, false],
      [false, true, true],
      [false, true, false],
      [false, false, true],
      [false, false, false],
    ];

    for (final c in cases) {
      final offline = c[0], sw = c[1], auto = c[2];
      final expected = offline || !sw || !auto;
      test('offline=$offline sw=$sw autoSync=$auto -> isDisabled=$expected',
          () {
        final s = guard.fromValues(
          source: 's',
          values: {
            OtzariaUpdateGuard.keyOfflineMode: offline,
            OtzariaUpdateGuard.keySoftwareAndBookUpdates: sw,
            OtzariaUpdateGuard.keyAutoSync: auto,
          },
        );
        expect(s.isDisabled, expected);
      });
    }

    test('שלושת הדגלים לא נרשמו כלל (null) — ברירת המחדל של אוצריא דלוקה', () {
      final s = guard.fromValues(source: 's', values: const {});
      expect(s.isDisabled, isFalse);
    });
  });

  group('unknown', () {
    test('found=false ו-isDisabled=false — חוסר ידיעה אסור שייחשב כבוי', () {
      // זו כל מטרת המחלקה: קריאה שנכשלה לא אמורה לגרום למחיקת ספרייה
      // חלקית תקינה מתוך הנחה שגויה שהעדכון האוטומטי כבוי.
      final s = guard.unknown('missing-file');
      expect(s.found, isFalse);
      expect(s.isDisabled, isFalse);
      expect(s.source, 'missing-file');
      expect(s.offlineMode, isNull);
      expect(s.softwareAndBookUpdatesEnabled, isNull);
      expect(s.autoSync, isNull);
    });
  });

  group('explanation', () {
    test('הטקסט שונה בין לא-ידוע, כבוי ופעיל', () {
      final unknown = guard.unknown('src').explanation;
      final disabled = guard.fromValues(
        source: 's',
        values: {OtzariaUpdateGuard.keyOfflineMode: true},
      ).explanation;
      final enabled =
          guard.fromValues(source: 's', values: const {}).explanation;

      // הניסוח עצמו מיועד למשתמש ומשתנה; מה שחייב להישמר הוא ששלושת
      // המצבים אומרים דברים שונים ואף אחד מהם אינו ריק.
      expect(unknown, isNotEmpty);
      expect(disabled, isNotEmpty);
      expect(enabled, isNotEmpty);

      expect(unknown, isNot(equals(disabled)));
      expect(unknown, isNot(equals(enabled)));
      expect(disabled, isNot(equals(enabled)));
    });
  });

  group('manualUpdateStillAvailable', () {
    // רק כשכבוי הסינכרון האוטומטי לבדו — הכפתור הידני באוצריא עדיין פעיל.
    for (final offline in [false, true]) {
      for (final sw in [false, true]) {
        for (final auto in [false, true]) {
          final expected = !auto && !offline && sw;
          test('offline=$offline sw=$sw autoSync=$auto -> $expected', () {
            final s = guard.fromValues(
              source: 's',
              values: {
                OtzariaUpdateGuard.keyOfflineMode: offline,
                OtzariaUpdateGuard.keySoftwareAndBookUpdates: sw,
                OtzariaUpdateGuard.keyAutoSync: auto,
              },
            );
            expect(s.manualUpdateStillAvailable, expected);
          });
        }
      }
    }

    test('הגדרות שלא נמצאו אינן מסומנות', () {
      expect(guard.unknown('x').manualUpdateStillAvailable, isFalse);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset_app/widgets/format.dart';

void main() {
  group('formatBytes', () {
    test('מתחת ל-KB נשאר בבתים', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('ספרה אחת אחרי הנקודה מתחת ל-100, בלי מעל', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(150 * 1024), '150 KB');
      expect(formatBytes(7 * 1024 * 1024 * 1024), '7.0 GB');
    });

    test('עיגול שחוצה את הסף עובר ליחידה הבאה', () {
      expect(formatBytes(1024 * 1024 - 1), '1.0 MB');
    });

    test('שלילי מוצג עם מינוס ולא בבתים', () {
      expect(formatBytes(-2048), '-2.0 KB');
    });

    test('היחידה הגדולה ביותר אינה חורגת מ-TB', () {
      expect(formatBytes(1024 * 1024 * 1024 * 1024 * 1024), '1024 TB');
    });
  });

  test('formatCount מפריד אלפים, גם בשלילי', () {
    expect(formatCount(0), '0');
    expect(formatCount(999), '999');
    expect(formatCount(1000), '1,000');
    expect(formatCount(1234567), '1,234,567');
    expect(formatCount(-1000), '-1,000');
  });

  test('formatQuantity: יחיד בנוסח משלו, השאר עם מספר', () {
    String books(int n) => formatQuantity(n, one: 'ספר אחד', many: 'ספרים');
    expect(books(1), 'ספר אחד');
    expect(books(0), '0 ספרים');
    expect(books(2), '2 ספרים');
    expect(books(1000), '1,000 ספרים');
  });

  group('hasInternalTerms', () {
    test('יחידות גודל אינן מונח פנימי', () {
      expect(hasInternalTerms('נשארו 5 GB'), isFalse);
      expect(hasInternalTerms('12.5MB להורדה'), isFalse);
      expect(hasInternalTerms('ספר אחד נמחק'), isFalse);
    });

    test('לטינית ומונחי מנוע נתפסים', () {
      expect(hasInternalTerms('שלב schema נכשל'), isTrue);
      expect(hasInternalTerms('גרסת סכמה'), isTrue);
      expect(hasInternalTerms('המסד פגום'), isTrue);
      expect(hasInternalTerms('ספרייה חלקית'), isTrue);
    });
  });

  test('userFacingError מחליף הודעה גולמית ומשאיר הודעה קריאה', () {
    expect(userFacingError(StateError('x'), fallback: 'תקלה'), 'תקלה');
    expect(userFacingError('   ', fallback: 'תקלה'), 'תקלה');
    expect(
        userFacingError('אין מספיק מקום', fallback: 'תקלה'), 'אין מספיק מקום');
  });

  test('formatDateTime מרפד לשתי ספרות, ו-null מוצג כקו', () {
    expect(formatDateTime(null), '—');
    expect(formatDateTime(DateTime(2026, 1, 5, 9, 7)), '05.01.2026 09:07');
  });
}

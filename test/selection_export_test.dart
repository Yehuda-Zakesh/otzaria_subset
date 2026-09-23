import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset/otzaria_subset.dart';

/// בדיקות לקובץ ייצוא הבחירה — מה שעובר בין מחשבים.
///
/// קובץ שמגיע מבחוץ הוא קלט לא אמין: כל פגם בו חייב להיות שגיאה ברורה
/// בייבוא, ולא בחירה אחרת (או ריקה) שנבנית בשקט.
void main() {
  const spec = SubsetSpec(
    categoryIds: {10, 2},
    includeBookIds: {5},
    excludeBookIds: {7},
  );

  Map<String, dynamic> validJson() => jsonDecode(SelectionExport(
        spec: spec,
        label: 'המחשב בבית',
        dbVersion: 42,
        exportedAt: DateTime.utc(2026, 9, 1, 12),
      ).encode()) as Map<String, dynamic>;

  test('סבב-חזרה שומר את הכלל ואת המטא-דאטה', () {
    final export = SelectionExport(
      spec: spec,
      label: 'המחשב בבית',
      dbVersion: 42,
      exportedAt: DateTime.utc(2026, 9, 1, 12),
    );

    final back = SelectionExport.decode(export.encode());

    expect(back.spec, spec);
    expect(back.label, 'המחשב בבית');
    expect(back.dbVersion, 42);
    expect(back.exportedAt, DateTime.utc(2026, 9, 1, 12));
  });

  test('שדות רשות חסרים אינם שגיאה', () {
    final back = SelectionExport.decode(
      const SelectionExport(spec: SubsetSpec(categoryIds: {1})).encode(),
    );
    expect(back.spec, const SubsetSpec(categoryIds: {1}));
    expect(back.label, isNull);
    expect(back.dbVersion, isNull);
    expect(back.exportedAt, isNull);
  });

  test('הקובץ נושא תג פורמט וגרסה', () {
    final json = validJson();
    expect(json['format'], SelectionExport.format);
    expect(json['version'], SelectionExport.version);
  });

  group('נדחה', () {
    void rejects(Object? Function() build, String reason) => expect(
          () => SelectionExport.decode(jsonEncode(build())),
          throwsFormatException,
          reason: reason,
        );

    test('JSON שבור', () {
      expect(
          () => SelectionExport.decode('{"format": '), throwsFormatException);
      expect(() => SelectionExport.decode(''), throwsFormatException);
    });

    test('שורש שאינו אובייקט', () {
      rejects(() => [1, 2], 'מערך');
      rejects(() => 'x', 'מחרוזת');
    });

    test('פורמט זר', () {
      rejects(() => {...validJson(), 'format': 'other'}, 'תג אחר');
      rejects(() => validJson()..remove('format'), 'בלי תג');
      rejects(
        () => const SubsetProfile(id: 'pc', label: 'x').toJson(),
        'קובץ פרופיל אינו קובץ בחירה',
      );
      rejects(() => LibraryCatalog.empty.toJson(), 'תצלום קטלוג');
    });

    test('גרסה חדשה מדי, חסרה או פגומה', () {
      rejects(
        () => {...validJson(), 'version': SelectionExport.version + 1},
        'חדשה מדי',
      );
      rejects(() => validJson()..remove('version'), 'חסרה');
      rejects(() => {...validJson(), 'version': 0}, 'אפס');
      rejects(() => {...validJson(), 'version': '1'}, 'מחרוזת');
    });

    test('בחירה חסרה או פגומה', () {
      rejects(() => validJson()..remove('spec'), 'בלי spec');
      rejects(() => {...validJson(), 'spec': 'x'}, 'spec שאינו אובייקט');
      rejects(
        () => {
          ...validJson(),
          'spec': {
            'categoryIds': [1, 'x'],
          },
        },
        'מזהה שאינו מספר',
      );
      rejects(
        () => {
          ...validJson(),
          'spec': {
            'categoryIds': [1.5],
          },
        },
        'מזהה שאינו שלם',
      );
      rejects(
        () => {
          ...validJson(),
          'spec': {'categoryIds': 3},
        },
        'שדה שאינו רשימה',
      );
    });

    test('בחירה שאינה שומרת דבר', () {
      rejects(
        () => {
          ...validJson(),
          'spec': {
            'excludeBookIds': [1],
          },
        },
        'רק החרגות',
      );
      rejects(() => {...validJson(), 'spec': <String, dynamic>{}}, 'ריקה');
    });
  });
}

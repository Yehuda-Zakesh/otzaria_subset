import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// מאיפה מגיעים עדכוני הספרייה.
enum UpdateSource {
  /// מהאינטרנט — ברירת המחדל, ולא דורשת מהמשתמש דבר.
  internet,

  /// מתיקייה מקומית (כונן נייד) — למחשב מנותק.
  folder,
}

/// ההגדרות שהמשתמש **כן** שולט בהן.
///
/// ## למה כל כך מעט
///
/// כל נתיב שהמשתמש נדרש להזין הוא נתיב שהוא יכול לטעות בו, והטעות כאן
/// עולה בספרייה שלמה. תיקיית העבודה ותיקיית האינדקס נגזרות ממיקום
/// הספרייה, ואין שום החלטה שהמשתמש יכול לקבל עליהן טוב יותר מאיתנו.
class AppSettings {
  /// דריסה ידנית של מיקום `seforim.db`. `null` = איתור אוטומטי.
  final String? libraryDbPathOverride;

  final UpdateSource updateSource;

  /// תיקיית העדכונים המקומית, כשהמקור הוא [UpdateSource.folder].
  final String? updateFolder;

  /// האם המשתמש אישר את ההבהרה שהתוכנה אינה קשורה לאוצריא.
  final bool disclaimerAccepted;

  const AppSettings({
    this.libraryDbPathOverride,
    this.updateSource = UpdateSource.internet,
    this.updateFolder,
    this.disclaimerAccepted = false,
  });

  static const AppSettings empty = AppSettings();

  AppSettings copyWith({
    String? libraryDbPathOverride,
    UpdateSource? updateSource,
    String? updateFolder,
    bool? disclaimerAccepted,
    bool clearOverride = false,
  }) =>
      AppSettings(
        libraryDbPathOverride: clearOverride
            ? null
            : (libraryDbPathOverride ?? this.libraryDbPathOverride),
        updateSource: updateSource ?? this.updateSource,
        updateFolder: updateFolder ?? this.updateFolder,
        disclaimerAccepted: disclaimerAccepted ?? this.disclaimerAccepted,
      );

  Map<String, dynamic> toJson() => {
        'libraryDbPathOverride': libraryDbPathOverride,
        'updateSource': updateSource.name,
        'updateFolder': updateFolder,
        'disclaimerAccepted': disclaimerAccepted,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        libraryDbPathOverride: json['libraryDbPathOverride'] as String?,
        updateSource: json['updateSource'] == UpdateSource.folder.name
            ? UpdateSource.folder
            : UpdateSource.internet,
        updateFolder: json['updateFolder'] as String?,
        disclaimerAccepted: json['disclaimerAccepted'] == true,
      );
}

/// קורא וכותב את [AppSettings] לתיקיית התמיכה של האפליקציה.
class AppSettingsStore {
  final File file;

  /// התיקייה שבה נשמר גם הפרופיל של המחשב הזה.
  final Directory profilesDir;

  AppSettingsStore._(this.file, this.profilesDir);

  /// מאגר בתיקייה נתונה — לבדיקות, שאין להן תיקיית תמיכה של אפליקציה.
  @visibleForTesting
  factory AppSettingsStore.at(String dir) => AppSettingsStore._(
        File(p.join(dir, 'settings.json')),
        Directory(p.join(dir, 'profiles')),
      );

  static Future<AppSettingsStore> open() async {
    final dir = await getApplicationSupportDirectory();
    return AppSettingsStore._(
      File(p.join(dir.path, 'settings.json')),
      Directory(p.join(dir.path, 'profiles')),
    );
  }

  /// קובץ פגום אינו מפיל את האפליקציה — הוא נטען כריק, והכול חוזר
  /// לברירות המחדל שממילא אינן דורשות מהמשתמש דבר.
  AppSettings load() {
    try {
      if (!file.existsSync()) return AppSettings.empty;
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) return AppSettings.empty;
      return AppSettings.fromJson(raw);
    } catch (_) {
      return AppSettings.empty;
    }
  }

  void save(AppSettings settings) {
    file.parent.createSync(recursive: true);
    // כתיבה אטומית: הגדרות חתוכות היו שולחות את המשתמש להתחיל מחדש.
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      flush: true,
    );
    // ‏rename מחליף קובץ קיים גם ב-Windows. מחיקה לפניו פתחה חלון שבו
    // קריסה משאירה בלי הגדרות בכלל — בדיוק מה שהכתיבה האטומית באה למנוע.
    tmp.renameSync(file.path);
  }
}

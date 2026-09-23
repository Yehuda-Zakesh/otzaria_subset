import 'dart:io';

import 'package:path/path.dart' as p;

/// נזרק כשביטול האינדקס נכשל או כשהנתיב אינו נראה כמו אינדקס.
class IndexInvalidationException implements Exception {
  final String message;
  const IndexInvalidationException(this.message);
  @override
  String toString() => 'IndexInvalidationException: $message';
}

/// תוצאת ביטול אינדקס.
class IndexInvalidationResult {
  /// התיקייה שטופלה.
  final String path;

  /// כמה קבצים נמחקו.
  final int filesDeleted;

  /// כמה בייטים שוחררו.
  final int bytesFreed;

  /// `true` כשרק נבדק ולא נמחק דבר.
  final bool dryRun;

  const IndexInvalidationResult({
    required this.path,
    required this.filesDeleted,
    required this.bytesFreed,
    required this.dryRun,
  });
}

/// מבטל את אינדקס החיפוש של אוצריא אחרי שהספרייה גוזמה.
///
/// ## למה זה נחוץ
///
/// אינדקס החיפוש של אוצריא הוא **Tantivy‏** ויושב **מחוץ** ל-`seforim.db`,
/// ולכן גיזום המסד אינו נוגע בו. גרוע מזה:
/// `IndexingRepository.dropOrphanedIndexEntries` מנקה רק מפתחות של ספרים
/// אישיים (`uid:`) ושל PDF, ו**במכוון אינו נוגע** במפתחות ספרים רשמיים
/// (`id:`) — כדי שטעינה חלקית של הספרייה לא תגרור אינדוקס-מחדש של שעות.
///
/// התוצאה: אחרי גיזום האינדקס ממשיך להחזיק כל ספר שנמחק. תוצאת חיפוש
/// לספר כזה **מוצגת כרגיל**, עם כותרת וקטע טקסט, ובלחיצה המשתמש מקבל
/// *"תוצאת החיפוש שייכת לאינדקס ישן. יש לעדכן את אינדקס החיפוש."* — אבחנה
/// שגויה שמזמינה בנייה מחדש מיותרת של שעות.
///
/// ## למה מחיקה ולא ניקוי מדויק
///
/// ניקוי מדויק דורש למחוק רשומות לפי `filePath` דרך ה-FFI של
/// `otzaria_search_engine` — תלות ב-crate של Rust, וסיכון להשאיר אינדקס
/// במצב חצי-עקבי. מחיקת התיקייה מביאה את אוצריא למצב שהיא כבר יודעת
/// לטפל בו: `indexedFilePaths` ריק, באנר אזהרה, ובנייה מחדש.
///
/// **הבנייה מחדש זולה כאן דווקא מפני שהספרייה חלקית** — מאות MB ולא
/// 7.4GB. זה מה שהופך את הפתרון הפשוט לנכון במקרה הזה.
class OtzariaIndexInvalidator {
  const OtzariaIndexInvalidator();

  /// שמות שמעידים על תיקיית אינדקס. די באחד מהם.
  ///
  /// `meta.json` הוא של Tantivy עצמו; שני האחרים הם של אוצריא
  /// (`otzaria_index_meta.json` נושא את גרסת סכמת האינדקס,
  /// `otzaria_catalogue_order.json` את חתימת סדר הקטלוג).
  static const List<String> indexMarkers = [
    'meta.json',
    'otzaria_index_meta.json',
    'otzaria_catalogue_order.json',
    '.managed-by-tantivy',
  ];

  /// הסמן שאוצריא כותבת כשהאינדקס הגיע מוכן מראש מה-installer.
  /// נוכחותו אומרת שהאינדקס מכסה את **כל** הספרייה, כלומר הבעיה קיימת
  /// מהרגע הראשון גם בלי שאף אינדוקס מקומי רץ.
  static const String prebuiltMarker = '.otzaria_prebuilt_index';

  /// מאתר את תיקיית האינדקס.
  ///
  /// [configuredIndexPath] הוא ההגדרה `key-index-path` של אוצריא, אם
  /// המשתמש שינה אותה. בלעדיה ברירת המחדל היא `index` **לצד** תיקיית
  /// הספרייה (אחותה, לא בתוכה) — כך אוצריא מחשבת זאת
  /// ב-`AppPaths.getIndexPath()`.
  static String resolveIndexDir({
    required String libraryPath,
    String? configuredIndexPath,
  }) {
    final configured = configuredIndexPath?.trim();
    if (configured != null && configured.isNotEmpty) return configured;
    return p.join(p.dirname(libraryPath), 'index');
  }

  /// האם [dir] נראה כמו תיקיית אינדקס.
  ///
  /// **זה השער שמונע מחיקה של התיקייה הלא נכונה.** נתיב ההגדרה מגיע
  /// מקובץ שהמשתמש יכול לערוך, ומחיקה רקורסיבית של מה שהוא מצביע אליו
  /// בלי בדיקה היא בדיוק סוג הכשל שאין ממנו חזרה.
  bool looksLikeIndex(String dir) {
    final directory = Directory(dir);
    if (!directory.existsSync()) return false;
    for (final marker in indexMarkers) {
      if (File(p.join(dir, marker)).existsSync()) return true;
    }
    // ‏Tantivy שומר קבצי segment בסיומות האלה. תיקייה שיש בה כאלה היא
    // אינדקס גם אם ה-meta נמחק.
    try {
      for (final entity in directory.listSync()) {
        if (entity is! File) continue;
        final ext = p.extension(entity.path);
        if (ext == '.idx' || ext == '.term' || ext == '.store') return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// האם האינדקס הגיע מוכן מראש מה-installer.
  bool isPrebuilt(String dir) => File(p.join(dir, prebuiltMarker)).existsSync();

  /// מוחק את תיקיית האינדקס, כך שאוצריא תבנה אותה מחדש מהספרייה החלקית.
  ///
  /// [dryRun] מחזיר את מה שהיה נמחק בלי לגעת בדיסק — מה שה-UI מציג
  /// למשתמש לפני שהוא מאשר.
  ///
  /// [protectedPaths] — קבצים שאסור שיימחקו יחד עם התיקייה (הספרייה
  /// עצמה). תיקייה שמכילה אחד מהם אינה אינדקס, גם אם יש בה `meta.json`.
  ///
  /// תיקייה שאינה קיימת אינה שגיאה: אין אינדקס, אין מה לבטל.
  IndexInvalidationResult invalidate(
    String dir, {
    bool dryRun = false,
    Iterable<String> protectedPaths = const [],
  }) {
    // נתיב יחסי נפתר מול תיקיית העבודה של התהליך, ושורש כונן הוא הכל —
    // מחיקה רקורסיבית של אחד מהם אינה הפיכה.
    if (!p.isAbsolute(dir) || p.equals(p.rootPrefix(dir), p.normalize(dir))) {
      throw IndexInvalidationException(
        'נתיב האינדקס אינו תיקייה מוחלטת שאפשר למחוק בבטחה: $dir',
      );
    }
    for (final protected in protectedPaths) {
      if (p.equals(dir, protected) || p.isWithin(dir, protected)) {
        throw IndexInvalidationException(
          'תיקיית האינדקס מכילה את $protected, ולכן לא נמחקה: $dir',
        );
      }
    }
    final directory = Directory(dir);
    if (!directory.existsSync()) {
      return IndexInvalidationResult(
        path: dir,
        filesDeleted: 0,
        bytesFreed: 0,
        dryRun: dryRun,
      );
    }
    if (!looksLikeIndex(dir)) {
      throw IndexInvalidationException(
        'הנתיב אינו נראה כמו אינדקס של אוצריא, ולכן לא נמחק: $dir. '
        'אם זו באמת תיקיית האינדקס — היא ריקה או פגומה, ואפשר למחוק '
        'אותה ידנית.',
      );
    }

    var files = 0;
    var bytes = 0;
    for (final entity in directory.listSync(recursive: true)) {
      if (entity is! File) continue;
      // ‏Tantivy אינו כותב את הספרייה לתוך האינדקס. מי שקורא ל-invalidate
      // בלי [protectedPaths] עדיין מוגן מפני נתיב שמצביע על תיקיית הספרייה.
      if (p.basename(entity.path).toLowerCase() == 'seforim.db') {
        throw IndexInvalidationException(
          'תיקיית האינדקס מכילה ספרייה (${entity.path}), ולכן לא נמחקה: $dir',
        );
      }
      files++;
      try {
        bytes += entity.lengthSync();
      } catch (_) {
        // קובץ שנעלם בין הרישום למדידה — לא משנה את ההחלטה.
      }
    }

    if (!dryRun) {
      try {
        directory.deleteSync(recursive: true);
      } catch (e) {
        throw IndexInvalidationException(
          'מחיקת תיקיית האינדקס נכשלה: $e. '
          'סביר שאוצריא פתוחה — יש לסגור אותה ולנסות שוב.',
        );
      }
    }

    return IndexInvalidationResult(
      path: dir,
      filesDeleted: files,
      bytesFreed: bytes,
      dryRun: dryRun,
    );
  }
}

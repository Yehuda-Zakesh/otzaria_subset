import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../models/profile.dart';
import '../models/subset_spec.dart';
import 'index_invalidator.dart';
import 'subset_builder.dart';
import 'subset_hasher.dart';
import 'subset_resolver.dart';

/// נזרק כשבנייה מחדש נכשלה. הספרייה הקיימת של המשתמש נשארת כשהייתה.
class SubsetRebuildException implements Exception {
  final String message;
  const SubsetRebuildException(this.message);
  @override
  String toString() => 'SubsetRebuildException: $message';
}

/// תוצאת בנייה מחדש.
class SubsetRebuildResult {
  final int? dbVersion;
  final int? schemaVersion;
  final String subsetHash;
  final Set<int> bookIds;
  final Set<int> keepCategories;
  final int resultBytes;

  /// האם תיקיית אינדקס החיפוש בוטלה, וכמה בייטים שוחררו.
  final IndexInvalidationResult? indexInvalidation;

  const SubsetRebuildResult({
    required this.dbVersion,
    required this.schemaVersion,
    required this.subsetHash,
    required this.bookIds,
    required this.keepCategories,
    required this.resultBytes,
    required this.indexInvalidation,
  });
}

/// בונה מחדש ספרייה חלקית ממסד מלא.
///
/// ## שני מסלולים, רכיב אחד
///
/// **שינוי סכמה.** קובצי ה-patch נפסלים כשהסכמה מתקדמת (כך גם באוצריא
/// עצמה), והמסלול היחיד הוא מסד מלא. אחריו גיזום מיידי חזרה לבחירה של
/// המשתמש.
///
/// **הבאת ספרים ממתינים.** ספר שנכנס לבחירה מאוחר אינו מגיע מ-patch — ראו
/// [PatchKeepResolution.pendingAcquisition]. גם הוא דורש מסד מלא, וגם הוא
/// נגמר בגיזום. אותה פעולה בדיוק, ולכן אותו רכיב.
///
/// ## למה המסד המלא חייב להתממש
///
/// ‏SQLite דורש גישה מקרית כדי לשאול. אי אפשר לשאול זרם שמתפרק, ולכן
/// המסד המלא **חייב** לשבת על הדיסק פעם אחת לפני שאפשר לגזום ממנו. מה
/// שכן נחסך: הארכיון הדחוס (~1.5GB) אינו צריך לנחות — המוריד מזרים אותו
/// ישר למחלץ. שיא התפוסה הוא ~7.4GB + התת-קבוצה, לא ~9.5GB.
///
/// זה המסלול **הנדיר**: שינוי סכמה קרה כחמש פעמים בהיסטוריה של הספרייה.
/// המסלול השוטף — patches מסוננים — אינו מממש מסד מלא כלל.
///
/// סינכרוני וחוסם — הרץ ב-`Isolate.run`.
class SubsetRebuilder {
  final SubsetBuilder builder;
  final SubsetResolver resolver;
  final SubsetHasher hasher;
  final OtzariaIndexInvalidator indexInvalidator;

  const SubsetRebuilder({
    this.builder = const SubsetBuilder(),
    this.resolver = const SubsetResolver(),
    this.hasher = const SubsetHasher(),
    this.indexInvalidator = const OtzariaIndexInvalidator(),
  });

  /// בונה מחדש את הספרייה של [spec] מ-[fullDbPath] אל [targetPath].
  ///
  /// [targetPath] רשאי להיות קיים — זו בנייה **מחדש**, ולכן החלפה היא
  /// המצב הרגיל. הקובץ הישן מוחלף רק אחרי שהחדש נבנה ואומת במלואו.
  ///
  /// [deleteFullDbWhenDone] מוחק את המסד המלא בסיום. זו ברירת המחדל:
  /// המשתמש גזם מלכתחילה מפני שאין לו מקום, והשארת 7.4GB על הדיסק
  /// מבטלת את כל התרגיל. `false` שימושי כשמייצרים כמה פרופילים מאותו
  /// מסד מלא — אז מוחקים פעם אחת בסוף.
  ///
  /// [indexDir] — תיקיית אינדקס החיפוש של אוצריא, לביטול. `null` מדלג.
  /// **מומלץ מאוד לספק אותה:** האינדקס שורד את הגיזום ומחזיק כל ספר
  /// שנמחק, וראו `OtzariaIndexInvalidator` להסבר למה זה מטעה את המשתמש.
  SubsetRebuildResult rebuild({
    required String fullDbPath,
    required String targetPath,
    required SubsetSpec spec,
    bool pruneCategories = true,
    bool deleteFullDbWhenDone = true,
    String? indexDir,
    void Function(String stage)? onStage,
    void Function(String table, int rows)? onTable,
    void Function(String table, int index, int total)? onTableStart,
    void Function(int done, int total)? onIndex,
  }) {
    final full = File(fullDbPath);
    if (!full.existsSync()) {
      throw SubsetRebuildException('המסד המלא אינו קיים: $fullDbPath');
    }

    final target = File(targetPath);
    final staged = File(p.join(
      target.parent.path,
      'rebuild-${DateTime.now().microsecondsSinceEpoch}.staging.db',
    ));

    try {
      onStage?.call('resolve');
      final resolved = _resolve(fullDbPath, spec);
      if (resolved.bookIds.isEmpty) {
        throw const SubsetRebuildException(
          'הבחירה ריקה — אין ספרים לבנות. יש לבחור קטגוריות או ספרים '
          'לפני בנייה מחדש.',
        );
      }

      onStage?.call('build');
      final build = builder.build(
        sourcePath: fullDbPath,
        targetPath: staged.path,
        bookIds: resolved.bookIds,
        keepCategoryIds: pruneCategories ? resolved.categoryIds : null,
        onStage: onStage,
        onTable: onTable,
        onTableStart: onTableStart,
        onIndex: onIndex,
      );

      onStage?.call('hash');
      final schemaVersion = build.schemaVersion;
      if (schemaVersion == null) {
        throw const SubsetRebuildException(
          'המסד המלא אינו מצהיר על גרסת סכמה (`schema_meta.'
          'db_schema_version`). בלעדיה אי אפשר לגבב את התוצאה, ולכן לא '
          'תהיה דרך לזהות סחף בעדכון הבא.',
        );
      }
      final subsetHash = _hashOf(staged.path, schemaVersion);

      onStage?.call('swap');
      _swap(staged, target);

      // ביטול האינדקס אחרון: כישלון שלו אינו מצדיק לגלגל אחורה ספרייה
      // שנבנתה בהצלחה, והמשתמש יכול למחוק את התיקייה גם ידנית.
      IndexInvalidationResult? invalidation;
      if (indexDir != null) {
        onStage?.call('invalidateIndex');
        try {
          invalidation = indexInvalidator.invalidate(indexDir);
        } on IndexInvalidationException {
          invalidation = null;
        }
      }

      if (deleteFullDbWhenDone) {
        onStage?.call('cleanup');
        try {
          full.deleteSync();
        } catch (_) {
          // מסד מלא שנשאר הוא בזבוז מקום, לא שגיאת נכונות.
        }
      }

      return SubsetRebuildResult(
        dbVersion: build.dbVersion,
        schemaVersion: schemaVersion,
        subsetHash: subsetHash,
        bookIds: resolved.bookIds,
        keepCategories: resolved.categoryIds,
        resultBytes: build.resultBytes,
        indexInvalidation: invalidation,
      );
    } finally {
      try {
        if (staged.existsSync()) staged.deleteSync();
      } catch (_) {}
    }
  }

  /// מעדכן פרופיל מתוצאת בנייה מחדש. פונקציה טהורה — הקורא שומר.
  SubsetProfile profileAfter(
    SubsetProfile profile,
    SubsetRebuildResult result, {
    required bool categoriesPruned,
    int severedLinkCount = 0,
  }) =>
      profile.copyWith(
        dbVersion: result.dbVersion,
        schemaVersion: result.schemaVersion,
        subsetHash: result.subsetHash,
        lastAppliedAt: DateTime.now(),
        categoriesPruned: categoriesPruned,
        severedLinkCount: severedLinkCount,
      );

  ({Set<int> bookIds, Set<int> categoryIds}) _resolve(
      String fullDbPath, SubsetSpec spec) {
    final db =
        sqlite3.sqlite3.open(fullDbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      final books = resolver.resolveBookIds(db, spec);
      return (
        bookIds: books,
        categoryIds: resolver.resolveCategoryIds(
          db,
          selectedCategoryIds: spec.categoryIds,
          bookIds: books,
        ),
      );
    } finally {
      db.close();
    }
  }

  String _hashOf(String path, int schemaVersion) {
    final db = sqlite3.sqlite3.open(path, mode: sqlite3.OpenMode.readOnly);
    try {
      return hasher.compute(db, schemaVersion: schemaVersion);
    } finally {
      db.close();
    }
  }

  /// מחליף את הספרייה בגרסה שנבנתה.
  ///
  /// הישנה נשמרת כ-`.bak` עד שההחלפה הצליחה. ב-Windows אין דריסה
  /// ב-`rename`, ולכן הסדר הוא ישן→`.bak`, חדש→מקום, ואז מחיקה. כשל
  /// באמצע מחזיר את הישן, וזה מה שמונע ממשתמש להישאר בלי ספרייה בכלל.
  void _swap(File staged, File target) {
    final backup = File('${target.path}.bak');
    try {
      if (backup.existsSync()) backup.deleteSync();
      final hadTarget = target.existsSync();
      if (hadTarget) target.renameSync(backup.path);
      try {
        staged.renameSync(target.path);
      } catch (_) {
        // שחזור שנכשל בעצמו אינו רשאי להסתיר את הסיבה המקורית: בלעדיה
        // אי אפשר להבין למה ההחלפה נפלה, והמשתמש נשאר עם ספרייה שיושבת
        // רק ב-`.bak` בלי שאף אחד אמר לו איפה היא.
        if (hadTarget) {
          try {
            backup.renameSync(target.path);
          } catch (restoreError) {
            throw SubsetRebuildException(
              'החלפת הספרייה נכשלה, וגם השחזור נכשל. הספרייה הקודמת '
              'נמצאת ב-${backup.path} ואפשר לשנות את שמה בחזרה '
              'ל-${target.path}. השגיאה: $restoreError',
            );
          }
        }
        rethrow;
      }
      // מכאן ואילך ההחלפה **הצליחה**. מחיקת הגיבוי היא ניקיון בלבד,
      // וכשל שלה אינו הופך בנייה מוצלחת לכישלון — הוא רק משאיר קובץ.
      if (hadTarget) {
        try {
          backup.deleteSync();
        } catch (_) {}
      }
    } on SubsetRebuildException {
      rethrow;
    } catch (e) {
      throw SubsetRebuildException('החלפת הספרייה נכשלה: $e');
    }
  }
}

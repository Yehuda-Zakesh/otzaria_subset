import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:seforim_library_updater/seforim_library_updater.dart';

/// אירוע שמגיע מ-`Isolate` של עבודה כבדה.
sealed class JobEvent {
  const JobEvent();
}

/// שלב בשם — בדיוק המחרוזות ש-`onStage` של המנוע מייצר.
class JobStage extends JobEvent {
  final String stage;
  const JobStage(this.stage);
}

/// טבלה שהועתקה, לחיווי התקדמות עדין יותר בבנייה.
class JobTable extends JobEvent {
  final String table;
  final int rows;
  const JobTable(this.table, this.rows);
}

/// אינדקס שנבנה מתוך סך הכול. שלב האינדקסים נמשך דקות ואין בו טבלאות,
/// ובלי דיווח כזה הוא נראה כמו תקיעה אחת ארוכה.
class JobIndex extends JobEvent {
  final int done;
  final int total;
  const JobIndex(this.done, this.total);
}

/// בייטים שהורדו מתוך סך הכול, כשהוא ידוע.
class JobBytes extends JobEvent {
  final int done;
  final int? total;
  const JobBytes(this.done, this.total);
}

class JobDone extends JobEvent {
  final Object? result;
  const JobDone(this.result);
}

class JobFailed extends JobEvent {
  final String message;
  const JobFailed(this.message);
}

/// בקשה שנשלחת ל-`Isolate`: הארגומנטים ויציאה לדיווח.
///
/// **רק פרימיטיבים ואובייקטים פשוטים.** closure שנוגע בשדה מופע לוכד
/// את `this` וזורק `object is unsendable` — ראו §9 ב-AGENTS.md.
class JobRequest<A> {
  final SendPort port;
  final A args;
  const JobRequest(this.port, this.args);
}

/// מריץ [entry] ב-`Isolate` ומחזיר את זרם האירועים שלו.
///
/// הזרם נסגר אחרי [JobDone] או [JobFailed], וה-`Isolate` נהרג איתו —
/// כולל כשהמנוי מבטל באמצע, וזה מה שנותן למסך ההתקדמות כפתור ביטול.
Stream<JobEvent> runJob<A>(
  void Function(JobRequest<A>) entry,
  A args,
) {
  final receive = ReceivePort();
  final controller = StreamController<JobEvent>();
  Isolate? isolate;
  var closed = false;

  Future<void> shutdown() async {
    if (closed) return;
    closed = true;
    receive.close();
    isolate?.kill(priority: Isolate.immediate);
    await controller.close();
  }

  receive.listen((Object? message) {
    if (message is! JobEvent) return;
    if (!controller.isClosed) controller.add(message);
    if (message is JobDone || message is JobFailed) unawaited(shutdown());
  });

  controller.onCancel = shutdown;

  Isolate.spawn(entry, JobRequest<A>(receive.sendPort, args)).then(
    (spawned) {
      if (closed) {
        spawned.kill(priority: Isolate.immediate);
      } else {
        isolate = spawned;
      }
    },
    onError: (Object error) {
      if (!controller.isClosed) controller.add(JobFailed('$error'));
      unawaited(shutdown());
    },
  );

  return controller.stream;
}

// ── קריאת קטלוג ─────────────────────────────────────────────────────

/// קורא את עץ הקטגוריות והספרים. כבד על מסד מלא, ולכן ב-`Isolate`.
void catalogEntry(JobRequest<String> req) {
  try {
    req.port.send(JobDone(readCatalogFromPath(req.args)));
  } catch (e) {
    req.port.send(JobFailed('קריאת הקטלוג נכשלה: $e'));
  }
}

/// ספירות וגרסאות של הספרייה שעל הדיסק.
void statsEntry(JobRequest<String> req) {
  try {
    final bytes = File(req.args).existsSync() ? File(req.args).lengthSync() : 0;
    final db = sqlite.sqlite3.open(req.args, mode: sqlite.OpenMode.readOnly);
    try {
      req.port.send(JobDone(readLibraryStats(db, fileBytes: bytes)));
    } finally {
      db.close();
    }
  } catch (e) {
    req.port.send(JobFailed('קריאת מצב הספרייה נכשלה: $e'));
  }
}

// ── פתירת בחירה (אומדן חי במסך הבחירה) ──────────────────────────────

class ResolveArgs {
  final String fullDbPath;
  final SubsetSpec spec;
  const ResolveArgs(this.fullDbPath, this.spec);
}

/// מעריך גודל וקישורים מנותקים עבור בחירה. רץ אחרי כל סימון בעץ, ולכן
/// הקורא חייב להשהות (debounce) לפני שהוא קורא לו.
void resolveEntry(JobRequest<ResolveArgs> req) {
  try {
    final db = sqlite.sqlite3
        .open(req.args.fullDbPath, mode: sqlite.OpenMode.readOnly);
    try {
      req.port.send(JobDone(const SubsetResolver().resolve(db, req.args.spec)));
    } finally {
      db.close();
    }
  } catch (e) {
    req.port.send(JobFailed('חישוב הבחירה נכשל: $e'));
  }
}

// ── בנייה מחדש ממסד מלא ─────────────────────────────────────────────

class RebuildArgs {
  final String fullDbPath;
  final String targetPath;
  final SubsetSpec spec;
  final bool pruneCategories;
  final bool deleteFullDbWhenDone;
  final String? indexDir;

  const RebuildArgs({
    required this.fullDbPath,
    required this.targetPath,
    required this.spec,
    this.pruneCategories = true,
    this.deleteFullDbWhenDone = true,
    this.indexDir,
  });
}

void rebuildEntry(JobRequest<RebuildArgs> req) {
  final port = req.port;
  try {
    final result = const SubsetRebuilder().rebuild(
      fullDbPath: req.args.fullDbPath,
      targetPath: req.args.targetPath,
      spec: req.args.spec,
      pruneCategories: req.args.pruneCategories,
      deleteFullDbWhenDone: req.args.deleteFullDbWhenDone,
      indexDir: req.args.indexDir,
      onStage: (stage) => port.send(JobStage(stage)),
      onTable: (table, rows) => port.send(JobTable(table, rows)),
      // דיווח **לפני** הטבלה. בלעדיו המסך קופא על הטבלה הקודמת לאורך כל
      // ההעתקה של טבלה גדולה, והמשתמש מסיק שהתוכנה תקועה ועוצר אותה.
      onTableStart: (table, index, total) => port.send(JobBytes(index, total)),
      onIndex: (done, total) => port.send(JobIndex(done, total)),
    );
    port.send(JobDone(result));
  } catch (e) {
    port.send(JobFailed('$e'));
  }
}

// ── החלת patch מסונן ────────────────────────────────────────────────

class ApplyPatchArgs {
  final String subsetPath;
  final String patchPath;
  final DeltaManifest manifest;
  final SubsetSpec spec;
  final String workDir;
  final bool categoriesPruned;
  final String? expectedHash;

  const ApplyPatchArgs({
    required this.subsetPath,
    required this.patchPath,
    required this.manifest,
    required this.spec,
    required this.workDir,
    required this.categoriesPruned,
    this.expectedHash,
  });
}

void applyPatchEntry(JobRequest<ApplyPatchArgs> req) {
  final port = req.port;
  try {
    final result = const SubsetUpdater().applyPatch(
      subsetPath: req.args.subsetPath,
      patchPath: req.args.patchPath,
      manifest: req.args.manifest,
      spec: req.args.spec,
      workDir: req.args.workDir,
      categoriesPruned: req.args.categoriesPruned,
      expectedHash: req.args.expectedHash,
      onStage: (stage) => port.send(JobStage(stage)),
    );
    port.send(JobDone(result));
  } catch (e) {
    port.send(JobFailed('$e'));
  }
}

// ── גזימה במקום ─────────────────────────────────────────────────────

class PruneArgs {
  final String path;

  /// הכלל של מה **נשאר**. מה שיורד נגזר ממנו בתוך ה-`Isolate` מול המסד
  /// עצמו, ולא מחושב במסך: כך המחיקה משתמשת בדיוק באותו כלל שבו המסד
  /// נבנה, ושתי הגרסאות אינן יכולות להיסחף זו מזו.
  final SubsetSpec spec;

  final bool pruneCategories;
  final String? indexDir;

  const PruneArgs({
    required this.path,
    required this.spec,
    this.pruneCategories = true,
    this.indexDir,
  });
}

/// מוחק ספרים מתוך ספרייה קיימת. זול לעומת בנייה מחדש — העבודה תלויה
/// במה שיורד, לא במה שנשאר.
void pruneEntry(JobRequest<PruneArgs> req) {
  final port = req.port;
  try {
    port.send(const JobStage('resolve'));
    final resolved = _resolveDrop(req.args);
    if (resolved.drop.isEmpty) {
      port.send(const JobFailed('אין ספרים למחוק.'));
      return;
    }
    final result = const SubsetPruner().prune(
      path: req.args.path,
      dropBookIds: resolved.drop,
      keepCategoryIds: resolved.keepCategories,
      onStage: (stage) => port.send(JobStage(stage)),
      onTable: (table, rows) => port.send(JobTable(table, rows)),
      onTableStart: (table, index, total) => port.send(JobBytes(index, total)),
    );
    // ביטול האינדקס אחרי המחיקה, מאותה סיבה שבבנייה מחדש: הוא שורד את
    // הגזימה ומחזיק ספרים שנמחקו.
    final indexDir = req.args.indexDir;
    if (indexDir != null) {
      port.send(const JobStage('invalidateIndex'));
      try {
        const OtzariaIndexInvalidator().invalidate(indexDir);
      } on IndexInvalidationException {
        // אינדקס שלא בוטל אינו מצדיק לבטל מחיקה שהצליחה.
      }
    }
    port.send(JobDone(result));
  } catch (e) {
    port.send(JobFailed('$e'));
  }
}

/// גוזר מהכלל מה יורד בפועל, מול המסד שעל הדיסק.
///
/// ההפרש נלקח מול **הספרים שקיימים שם עכשיו** ולא מול הקטלוג שבמסך:
/// המסך יכול להיות ישן בכמה שניות, והמחיקה חייבת לפעול על מה שיש.
({Set<int> drop, Set<int>? keepCategories}) _resolveDrop(PruneArgs args) {
  final db = sqlite.sqlite3.open(args.path, mode: sqlite.OpenMode.readOnly);
  try {
    const resolver = SubsetResolver();
    final keep = resolver.resolveBookIds(db, args.spec);
    final all = <int>{
      for (final row in db.select('SELECT id FROM book'))
        (row['id'] as num).toInt(),
    };
    return (
      drop: all.difference(keep),
      keepCategories: args.pruneCategories
          ? resolver.resolveCategoryIds(
              db,
              selectedCategoryIds: args.spec.categoryIds,
              bookIds: keep,
            )
          : null,
    );
  } finally {
    db.close();
  }
}

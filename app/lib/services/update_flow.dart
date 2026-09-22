import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:otzaria_subset/otzaria_subset.dart';
import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:zstandard/zstandard.dart';

import '../jobs/jobs.dart';
import '../state/app_settings.dart';
import 'zstd_stream.dart';

/// השלב שבו הזרימה נמצאת. ה-UI מתרגם אותו לכותרת.
enum FlowStage {
  discovering,
  downloading,
  extracting,
  filtering,
  applying,
  verifying,
  rebuilding,
  done,
}

/// דיווח התקדמות אחד.
class FlowProgress {
  final FlowStage stage;
  final String message;

  /// ‏0..1 כשהוא ידוע. `null` = שלב שאי אפשר למדוד את אורכו.
  final double? fraction;

  const FlowProgress(this.stage, this.message, {this.fraction});
}

/// מה שהסתיים בזרימה — מה שהמסכים צריכים אחריה.
class FlowOutcome {
  final SubsetProfile profile;

  /// ספרים שהמשתמש בחר ולא התקבלו — ראו §5 ב-AGENTS.md. **חייבים
  /// להגיע למסך**: ספר שביקש ולא קיבל לא יכול להישאר בלוג.
  final Set<int> pendingAcquisition;

  final bool rebuilt;

  const FlowOutcome({
    required this.profile,
    required this.pendingAcquisition,
    required this.rebuilt,
  });
}

/// נזרק על כשל בזרימה, אחרי שכל מה שאפשר נוקה.
class FlowException implements Exception {
  final String message;
  const FlowException(this.message);
  @override
  String toString() => message;
}

/// מחברת את הגילוי, התכנון, ההורדה והסינון לזרימה אחת.
///
/// ## שני מסלולים, והבחירה ביניהם אינה שלנו
///
/// ‏`LibraryUpdatePlanner` מחזיר `LibraryUpdatePlan.kind`, וזה מה שקובע:
/// ‏`delta` פירושו סינון והחלה על הספרייה הקיימת, `fullDownload` פירושו
/// בנייה מחדש ממסד מלא. אין כאן החלטה עצמאית — התכנון של אפסטרים מכיר
/// את המגבלות שלו (סכמה חדשה, פורמט patch חדש, שרשרת ארוכה מדי) טוב
/// יותר ממה שאפשר להסיק כאן.
class SubsetUpdateFlow {
  /// מאיפה מגיעים העדכונים. ברירת המחדל היא האינטרנט, ותיקייה מקומית
  /// היא המסלול של מחשב מנותק.
  final UpdateSource updateSource;

  /// תיקיית העדכונים המקומית, כש-[updateSource] היא תיקייה.
  final String? updateFolder;

  /// הספרייה של המחשב הזה — ה-`seforim.db` שאוצריא משתמשת בו.
  final String subsetPath;

  /// תיקיית עבודה — **על אותו כרך** כמו [subsetPath].
  final String workDir;

  /// תיקיית אינדקס החיפוש של אוצריא, לביטול אחרי בנייה מחדש.
  final String? indexDir;

  const SubsetUpdateFlow({
    required this.subsetPath,
    required this.workDir,
    this.updateSource = UpdateSource.internet,
    this.updateFolder,
    this.indexDir,
  });

  LibraryReleaseSource _openSource() {
    if (updateSource == UpdateSource.folder) {
      final dir = updateFolder;
      if (dir == null || dir.isEmpty) {
        throw const FlowException('לא נבחרה תיקיית עדכונים.');
      }
      return LocalMirrorLibraryReleaseClient(mirrorDir: dir);
    }
    return GithubLibraryReleaseClient();
  }

  /// גילוי ותכנון. אינו נוגע בספרייה של המשתמש.
  Future<LibraryUpdatePlan> check() async {
    final source = _openSource();
    try {
      final local = _localVersion();
      final discovery = await LibraryUpdateDiscovery(client: source).discover(
        allowPrerelease: false,
      );
      return const LibraryUpdatePlanner().plan(
        localVersion: local.dbVersion,
        hasLocalVersionMeta: local.hasVersionMeta,
        latestVersion: discovery.latestVersion,
        edges: discovery.edges,
        latestFullDbAsset: discovery.latestFullDbAsset,
        fullDbReleaseTag: discovery.fullDbReleaseTag,
        latestFullDbVersion: discovery.latestFullDbVersion,
        latestContentTag: discovery.latestContentTag,
        blockingSchemaVersion: discovery.blockingSchemaVersion,
        blockingPatchFormatVersion: discovery.blockingPatchFormatVersion,
      );
    } finally {
      source.dispose();
    }
  }

  /// מסד חלקי שעוד לא נבנה נחשב גרסה 0 — וזה מה שמנתב את התכנון
  /// למסלול ההורדה המלאה, כי אין מה להחיל עליו patch.
  LocalDbVersion _localVersion() {
    if (!File(subsetPath).existsSync()) {
      return const LocalDbVersion(
        dbVersion: 0,
        schemaVersion: null,
        hasVersionMeta: false,
      );
    }
    return const LocalDbVersionReader().read(subsetPath);
  }

  /// גוזמת את הספרייה הקיימת **במקום**, לפי [spec].
  ///
  /// ## למה המקור והיעד הם אותו קובץ
  ///
  /// המשתמש כבר הוריד את הספרייה המלאה דרך אוצריא. אין שום סיבה להוריד
  /// אותה שוב — הגזימה בונה קובץ חדש לצדה, מאמתת אותו, ורק אז מחליפה
  /// אטומית. המקור נמחק ברגע ההחלפה ולא לפניה.
  ///
  /// ‏`deleteFullDbWhenDone` חייב להיות `false` כאן: המסד ה"מלא" והיעד
  /// הם אותו נתיב, ומחיקה בסוף הייתה מוחקת דווקא את התוצאה.
  ///
  /// [estimatedBytes] הוא אומדן גודל התוצאה, לבדיקת מקום פנוי. הבנייה
  /// יוצרת קובץ שני לצד הקיים לפני שהיא מחליפה, ולכן היא **צורכת** מקום
  /// לפני שהיא משחררת אותו — וזה המקום שבו משתמש שנשאר בלי מקום ייתקע.
  ///
  /// ## שני מסלולים, והמהיר נבחר מאליו
  ///
  /// מסד שאנחנו בנינו נגזם **במקום**: מוחקים את מה שיורד ומשחררים את
  /// הדפים, ולכן העלות תלויה בגודל המחיקה ולא בגודל מה שנשאר. מסד שהגיע
  /// מאוצריא אינו תומך בכך, ולכן הגזימה הראשונה היא תמיד בנייה מלאה.
  Stream<FlowProgress> prune({
    required SubsetProfile profile,
    required SubsetSpec spec,
    required void Function(SubsetProfile profile) onProfile,
    required void Function(FlowOutcome outcome) onOutcome,
    int? estimatedBytes,
    bool Function()? isCancelled,
  }) async* {
    Directory(workDir).createSync(recursive: true);

    // המסלול המהיר זמין רק על מסד שאנחנו בנינו — ראו SubsetPruner.
    if (SubsetPruner.supportsInPlace(subsetPath)) {
      yield* _pruneInPlace(
        profile: profile,
        spec: spec,
        onProfile: onProfile,
        onOutcome: onOutcome,
      );
      return;
    }

    if (estimatedBytes != null &&
        DiskSpaceProbe.isKnownInsufficient(subsetPath, estimatedBytes)) {
      throw FlowException(
        'אין מספיק מקום פנוי בכונן. צריך בערך '
        '${(estimatedBytes / (1 << 30)).toStringAsFixed(1)}GB פנויים '
        'זמנית, ורק בסוף התהליך המקום מתפנה.',
      );
    }
    var current = profile;

    yield const FlowProgress(FlowStage.rebuilding, 'מכין…');
    await for (final event in runJob(
      rebuildEntry,
      RebuildArgs(
        fullDbPath: subsetPath,
        targetPath: subsetPath,
        spec: spec,
        deleteFullDbWhenDone: false,
        indexDir: indexDir,
      ),
    )) {
      switch (event) {
        case JobStage(:final stage):
          yield FlowProgress(FlowStage.rebuilding, stageLabel(stage));
        case JobTable(:final table, :final rows):
          yield FlowProgress(
            FlowStage.rebuilding,
            'מעתיק $table — $rows שורות',
          );
        case JobFailed(:final message):
          throw FlowException(message);
        case JobDone(:final result):
          final rebuild = result! as SubsetRebuildResult;
          current = const SubsetRebuilder().profileAfter(
            profile.copyWith(spec: spec),
            rebuild,
            categoriesPruned: true,
          );
          onProfile(current);
        case JobBytes(:final done, :final total):
          yield _tableProgress(done, total);
        case JobIndex(:final done, :final total):
          yield _indexProgress(done, total);
      }
    }

    onOutcome(FlowOutcome(
      profile: current,
      pendingAcquisition: const {},
      rebuilt: true,
    ));
    yield const FlowProgress(FlowStage.done, 'הסתיים.');
  }

  /// המסלול המהיר: מוחק את הספרים במקום ומשחרר את הדפים.
  ///
  /// ה-hash של הספרייה משתנה כאן, אבל הוא אינו מחושב מחדש: חישובו דורש
  /// קריאה של כל המסד — בדיוק העלות שהמסלול הזה בא לחסוך. הוא מתאפס,
  /// והעדכון הבא פשוט אינו מאמת מולו. אימות מול ערך **שגוי** היה גרוע
  /// בהרבה מאי-אימות.
  Stream<FlowProgress> _pruneInPlace({
    required SubsetProfile profile,
    required SubsetSpec spec,
    required void Function(SubsetProfile profile) onProfile,
    required void Function(FlowOutcome outcome) onOutcome,
  }) async* {
    var current = profile;
    yield const FlowProgress(FlowStage.rebuilding, 'מוחק…');

    await for (final event in runJob(
      pruneEntry,
      PruneArgs(
        path: subsetPath,
        spec: spec,
        indexDir: indexDir,
      ),
    )) {
      switch (event) {
        case JobStage(:final stage):
          yield FlowProgress(FlowStage.rebuilding, stageLabel(stage));
        case JobTable(:final table, :final rows):
          if (rows > 0) {
            yield FlowProgress(FlowStage.rebuilding, 'מנקה $table');
          }
        case JobBytes(:final done, :final total):
          yield _tableProgress(done, total);
        case JobIndex(:final done, :final total):
          yield _indexProgress(done, total);
        case JobFailed(:final message):
          throw FlowException(message);
        case JobDone():
          // ה-hash מתאפס: הוא כבר אינו מתאר את המסד, וחישובו מחדש היה
          // קורא את כולו — בדיוק העלות שהמסלול הזה חוסך.
          current = profile.copyWith(
            clearSubsetHash: true,
            spec: spec,
            lastAppliedAt: DateTime.now(),
            categoriesPruned: true,
          );
          onProfile(current);
      }
    }

    onOutcome(FlowOutcome(
      profile: current,
      pendingAcquisition: const {},
      rebuilt: true,
    ));
    yield const FlowProgress(FlowStage.done, 'הסתיים.');
  }

  /// מריצה את [plan]. [onOutcome] נקרא פעם אחת לפני שהזרם נסגר.
  Stream<FlowProgress> run({
    required LibraryUpdatePlan plan,
    required SubsetProfile profile,
    required SubsetSpec spec,
    required void Function(SubsetProfile profile) onProfile,
    required void Function(FlowOutcome outcome) onOutcome,
    bool Function()? isCancelled,
  }) async* {
    Directory(workDir).createSync(recursive: true);
    var current = profile;
    final pending = <int>{};
    var rebuilt = false;

    switch (plan.kind) {
      case LibraryUpdatePlanKind.none:
        yield const FlowProgress(FlowStage.done, 'הספרייה מעודכנת.');
      case LibraryUpdatePlanKind.blocked:
        throw FlowException(plan.reason ?? 'העדכון חסום.');
      case LibraryUpdatePlanKind.fullDownload:
        await for (final step in _runFull(
          plan: plan,
          profile: current,
          spec: spec,
          isCancelled: isCancelled,
          onProfile: (next) {
            current = next;
            onProfile(next);
          },
        )) {
          yield step;
        }
        rebuilt = true;
        final followUp = plan.followUpDelta;
        if (followUp != null) {
          await for (final step in _runDelta(
            plan: followUp,
            profile: current,
            spec: spec,
            pending: pending,
            isCancelled: isCancelled,
            onProfile: (next) {
              current = next;
              onProfile(next);
            },
          )) {
            yield step;
          }
        }
      case LibraryUpdatePlanKind.delta:
        await for (final step in _runDelta(
          plan: plan,
          profile: current,
          spec: spec,
          pending: pending,
          isCancelled: isCancelled,
          onProfile: (next) {
            current = next;
            onProfile(next);
          },
        )) {
          yield step;
        }
    }

    onOutcome(FlowOutcome(
      profile: current,
      pendingAcquisition: pending,
      rebuilt: rebuilt,
    ));
    yield const FlowProgress(FlowStage.done, 'הסתיים.');
  }

  // ── מסלול ה-patch ────────────────────────────────────────────────

  Stream<FlowProgress> _runDelta({
    required LibraryUpdatePlan plan,
    required SubsetProfile profile,
    required SubsetSpec spec,
    required Set<int> pending,
    required void Function(SubsetProfile) onProfile,
    bool Function()? isCancelled,
  }) async* {
    var current = profile;
    final downloader = PatchDownloader(decompress: decompressOneShot);
    final dest = Directory(p.join(workDir, 'patches'))
      ..createSync(recursive: true);

    try {
      final steps = plan.deltaSteps;
      for (var i = 0; i < steps.length; i++) {
        final edge = steps[i];
        final entry = edge.manifest.patchFiles.first;
        final url = edge.patchFileUrls[entry.file];
        if (url == null) {
          throw FlowException('חסר נתיב להורדת ${entry.file}');
        }

        final label = 'עדכון ${i + 1} מתוך ${steps.length} '
            '(${edge.fromVersion} ← ${edge.toVersion})';
        yield FlowProgress(FlowStage.downloading, '$label — מוריד…');

        final patchPath = await downloader.downloadAndExtract(
          patchFile: entry,
          downloadUrl: url,
          destDir: dest,
          isCancelled: isCancelled,
        );

        try {
          // הסינון וההחלה הם פעולה אחת ב-`SubsetUpdater`: הסינון חייב
          // לרוץ מול אותה קבוצת ספרים שההחלה תראה.
          await for (final event in runJob(
            applyPatchEntry,
            ApplyPatchArgs(
              subsetPath: subsetPath,
              patchPath: patchPath,
              manifest: edge.manifest,
              spec: spec,
              workDir: workDir,
              categoriesPruned: current.categoriesPruned,
              expectedHash: current.subsetHash,
            ),
          )) {
            switch (event) {
              case JobStage(:final stage):
                yield FlowProgress(
                  _stageOf(stage),
                  '$label — ${stageLabel(stage)}',
                );
              case JobFailed(:final message):
                throw FlowException(message);
              case JobDone(:final result):
                final update = result! as SubsetUpdateResult;
                pending.addAll(update.pendingAcquisition);
                current = const SubsetUpdater().profileAfter(
                  current,
                  update,
                  schemaVersion: edge.manifest.toSchemaVersion,
                );
                onProfile(current);
              case JobTable():
              case JobBytes():
              case JobIndex():
                break;
            }
          }
        } finally {
          _deleteQuietly(patchPath);
        }
      }
    } finally {
      downloader.dispose();
      _deleteDirQuietly(dest.path);
    }
  }

  // ── מסלול ההורדה המלאה ───────────────────────────────────────────

  Stream<FlowProgress> _runFull({
    required LibraryUpdatePlan plan,
    required SubsetProfile profile,
    required SubsetSpec spec,
    required void Function(SubsetProfile) onProfile,
    bool Function()? isCancelled,
  }) async* {
    final asset = plan.fullDbAsset;
    if (asset == null) {
      throw const FlowException('אין נכס של ספרייה מלאה בתכנון.');
    }
    final fullPath = p.join(workDir, 'seforim-full.db');

    // שיא התפוסה הוא המסד המלא ועוד התת-קבוצה. אי אפשר להוריד מזה:
    // ‏SQLite דורש גישה מקרית, ואי אפשר לגזום זרם שמתפרק.
    final needed =
        ZstdFileStream.contentSizeOf(asset.downloadUrl) ?? asset.size * 6;
    if (DiskSpaceProbe.isKnownInsufficient(workDir, needed)) {
      throw FlowException(
        'אין מספיק מקום פנוי ב-$workDir. נדרשים לפחות '
        '${(needed / (1 << 30)).toStringAsFixed(1)}GB זמניים לבנייה מחדש. '
        'אפשר להפנות את תיקיית העבודה לדיסק חיצוני בהגדרות.',
      );
    }

    yield const FlowProgress(FlowStage.extracting, 'מחלץ ספרייה מלאה…');
    try {
      if (PatchDownloader.isRemoteUrl(asset.downloadUrl)) {
        // מהרשת ישר למחלץ — הארכיון הדחוס אינו נוחת על הדיסק.
        final client = http.Client();
        try {
          final request = http.Request('GET', Uri.parse(asset.downloadUrl));
          final response = await client.send(request);
          if (response.statusCode != 200) {
            throw FlowException('ההורדה נכשלה (קוד ${response.statusCode}).');
          }
          await decompressStreamToFile(
            response.stream,
            fullPath,
            isCancelled: isCancelled,
          );
        } finally {
          client.close();
        }
      } else {
        // המראה כבר על הדיסק — מפרקים ממנה ישירות, בלי העתק ביניים.
        final streamed = await ZstdFileStream.decompressFileToFile(
          asset.downloadUrl,
          fullPath,
          isCancelled: isCancelled,
        );
        if (!streamed) {
          throw const FlowException('פירוק zstd בהזרמה אינו זמין כאן.');
        }
      }

      yield const FlowProgress(FlowStage.rebuilding, 'בונה ספרייה חלקית…');
      await for (final event in runJob(
        rebuildEntry,
        RebuildArgs(
          fullDbPath: fullPath,
          targetPath: subsetPath,
          spec: spec,
          indexDir: indexDir,
        ),
      )) {
        switch (event) {
          case JobStage(:final stage):
            yield FlowProgress(FlowStage.rebuilding, stageLabel(stage));
          case JobTable(:final table, :final rows):
            yield FlowProgress(
              FlowStage.rebuilding,
              'מעתיק $table — $rows שורות',
            );
          case JobFailed(:final message):
            throw FlowException(message);
          case JobDone(:final result):
            final rebuild = result! as SubsetRebuildResult;
            onProfile(const SubsetRebuilder().profileAfter(
              profile,
              rebuild,
              categoriesPruned: true,
            ));
          case JobBytes(:final done, :final total):
            yield _tableProgress(done, total);
          case JobIndex(:final done, :final total):
            yield _indexProgress(done, total);
        }
      }
    } finally {
      _deleteQuietly(fullPath);
    }
  }

  // ── עזר ──────────────────────────────────────────────────────────

  static FlowStage _stageOf(String stage) => switch (stage) {
        'filter' => FlowStage.filtering,
        'verifyLocal' || 'verify' || 'hash' => FlowStage.verifying,
        _ => FlowStage.applying,
      };

  static void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // קובץ זמני שנשאר הוא בזבוז מקום, לא שגיאת נכונות.
    }
  }

  static void _deleteDirQuietly(String path) {
    try {
      final dir = Directory(path);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// שמות השלבים של המנוע בעברית, לתצוגה.
String stageLabel(String stage) => switch (stage) {
      'verifyLocal' => 'מאמת את הספרייה הקיימת',
      'filter' => 'מסנן את העדכון לבחירה',
      'apply' => 'מחיל',
      'hash' => 'מסכם',
      'verify' => 'מאמת',
      'swap' => 'מחליף',
      'resolve' => 'פותר את הבחירה',
      'preflight' => 'בדיקה מקדימה',
      'schema' => 'בונה סכמה',
      'copy' => 'מעתיק שורות',
      'index' => 'בונה אינדקסים',
      'indexes' => 'בונה אינדקסים',
      'analyze' => 'מנתח',
      'invalidateIndex' => 'מבטל את אינדקס החיפוש',
      'delete' => 'מוחק ספרים',
      'reclaim' => 'משחרר מקום',
      'cleanup' => 'מנקה',
      _ => stage,
    };

/// פירוק חד-פעמי, ל-patches בלבד — הם עשרות מגהבייטים ונכנסים לזיכרון.
Future<Uint8List?> decompressOneShot(Uint8List compressed) async {
  try {
    return await Zstandard().decompress(compressed);
  } catch (_) {
    return null;
  }
}

/// הודעת התקדמות להעתקת טבלה.
///
/// הטבלאות אינן שוות בגודלן ולכן היחס הוא קירוב גס — אבל פס שזז הוא
/// ההבדל בין "עובד" ל"תקוע" בעיני המשתמש, וזו הטעות שכבר קרתה כאן.
FlowProgress _tableProgress(int done, int? total) => FlowProgress(
      FlowStage.rebuilding,
      total == null ? 'מעתיק טבלה $done' : 'מעתיק טבלה $done מתוך $total',
      fraction: total == null || total == 0 ? null : done / total,
    );

/// הודעת התקדמות לבניית אינדקס.
///
/// שלב האינדקסים הוא הארוך ביותר אחרי ההעתקה ואין בו טבלאות לדווח
/// עליהן — בלי המונה הזה הוא נראה כמו תקיעה אחת ארוכה.
FlowProgress _indexProgress(int done, int total) => FlowProgress(
      FlowStage.rebuilding,
      'בונה אינדקס $done מתוך $total',
      fraction: total == 0 ? null : done / total,
    );

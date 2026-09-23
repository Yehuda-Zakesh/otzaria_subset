import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/seforim_library_updater.dart';

import 'error_report.dart';

/// הכנת כונן נייד למחשב בלי אינטרנט.
///
/// ## מה נעשה כאן ומה לא
///
/// את כל ההורדה עושה `LibraryMirrorExporter` של אפסטרים — הוא זה שיודע
/// בדיוק איזה מבנה `LocalMirrorLibraryReleaseClient` קורא, מחדש הורדה
/// שנקטעה, מדלג על קובץ שכבר שלם, בודק מקום פנוי, מרכיב מסד מפוצל,
/// וכותב את `releases.json` **אחרון ובאטומיות** — כך שכונן חצי־מוכן
/// נראה במחשב השני כ"אין עדכונים בתיקייה" ולא כעדכון שבור. כאן רק
/// בוחרים מה להוריד, ומתרגמים את התוצאה לשפה של המשתמש.
///
/// ## למה לא ב-`Isolate`
///
/// העבודה כולה קלט/פלט אסינכרוני, וה-sha256 רץ נייטיבית במנות. `Isolate`
/// היה מאלץ ביטול בהריגה במקום ביטול מסודר, ואת הבדיקות להריץ בלי שרת
/// מדומה (לקוח HTTP מדומה אינו ניתן לשליחה).

/// המצב של המחשב הלא־מקוון, כפי שנשמר לכונן. זה חצי הלחיצה של
/// "איזו גרסה יש לו": המחשב המקוון לא יכול לדעת את זה בעצמו.
class OfflineComputerStatus {
  /// שם הקובץ בתיקיית הכונן. לצד `releases.json`, ומחוץ ל-`assets/`
  /// שהייצוא מנקה.
  static const String fileName = 'computer-status.json';

  /// גרסת הפורמט. קובץ בגרסה אחרת נחשב כאילו אינו קיים — עדיף להוריד
  /// יותר מלנחש.
  static const int formatVersion = 1;

  /// גרסת הספרייה במחשב הלא־מקוון. `null` = לא ידועה (ספרייה חסרה או
  /// ישנה מדי), ואז העדכון היחיד שיעבוד שם הוא הספרייה המלאה.
  final int? libraryVersion;

  final DateTime savedAt;

  /// שם המחשב, רק כדי שהמשתמש יזהה של מי המצב שעל הכונן.
  final String computerName;

  const OfflineComputerStatus({
    required this.libraryVersion,
    required this.savedAt,
    required this.computerName,
  });

  /// קורא את גרסת הספרייה שב-[libraryDbPath], באותה דרך שבה זרימת העדכון
  /// קוראת אותה — כדי שהכונן ייבנה בדיוק מאותה נקודה שממנה יתוכנן העדכון.
  static OfflineComputerStatus capture(String? libraryDbPath) {
    int? version;
    if (libraryDbPath != null && File(libraryDbPath).existsSync()) {
      final local = const LocalDbVersionReader().read(libraryDbPath);
      if (local.hasVersionMeta && local.dbVersion > 0) {
        version = local.dbVersion;
      }
    }
    return OfflineComputerStatus(
      libraryVersion: version,
      savedAt: DateTime.now(),
      computerName: Platform.localHostname,
    );
  }

  Map<String, dynamic> toJson() => {
        'format': formatVersion,
        'libraryVersion': libraryVersion,
        'savedAt': savedAt.toUtc().toIso8601String(),
        'computer': computerName,
      };

  /// `null` על כל קובץ שאינו בפורמט שלנו — ואז הכונן נבנה כאילו אין מצב.
  static OfflineComputerStatus? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    if (json['format'] != formatVersion) return null;
    final version = json['libraryVersion'];
    final savedAt = DateTime.tryParse('${json['savedAt']}');
    if (savedAt == null) return null;
    if (version != null && version is! int) return null;
    return OfflineComputerStatus(
      libraryVersion: version as int?,
      savedAt: savedAt.toLocal(),
      computerName:
          json['computer'] is String ? json['computer'] as String : '',
    );
  }

  /// כתיבה אטומית: שליפת הכונן באמצע לא תשאיר קובץ חתוך שייקרא כמצב.
  Future<void> writeTo(String dir) async {
    await Directory(dir).create(recursive: true);
    final target = File(p.join(dir, fileName));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(toJson()), flush: true);
    await tmp.rename(target.path);
  }

  static Future<OfflineComputerStatus?> readFrom(String dir) async {
    final file = File(p.join(dir, fileName));
    try {
      if (!await file.exists()) return null;
      return fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }
}

/// היכן ההכנה עומדת. ה-UI מציג מזה רק מד ושורת טקסט.
enum MirrorPhase { preparing, downloading, checking }

class MirrorProgress {
  final MirrorPhase phase;
  final int doneBytes;

  /// `null` כל עוד לא ידוע כמה יש להוריד.
  final int? totalBytes;
  final int doneFiles;
  final int totalFiles;

  const MirrorProgress({
    required this.phase,
    this.doneBytes = 0,
    this.totalBytes,
    this.doneFiles = 0,
    this.totalFiles = 0,
  });

  double? get fraction {
    final total = totalBytes;
    if (phase != MirrorPhase.downloading || total == null || total <= 0) {
      return null;
    }
    return (doneBytes / total).clamp(0.0, 1.0);
  }
}

/// מה שהכונן מחזיק בסוף.
class MirrorBuildResult {
  /// למחשב השני כבר יש הכול — הכונן לא השתנה.
  final bool upToDate;

  /// האם על הכונן יש את הספרייה המלאה.
  final bool includesFullLibrary;

  /// האם מה שעל הכונן מספיק לעדכן את המחשב השני. `null` = לא ידוע, כי
  /// לא נשמר מצב שלו.
  final bool? coversOtherComputer;

  /// המצב של המחשב השני שלפיו נבנה הכונן, אם היה כזה.
  final OfflineComputerStatus? status;

  const MirrorBuildResult({
    required this.upToDate,
    required this.includesFullLibrary,
    required this.coversOtherComputer,
    required this.status,
  });
}

/// כשל בהכנה, עם הודעה שמותר להציג.
class MirrorBuildException implements Exception {
  final String message;
  const MirrorBuildException(this.message);
  @override
  String toString() => message;
}

class MirrorBuildCancelled implements Exception {
  const MirrorBuildCancelled();
}

/// שלושת המסלולים. ראו [MirrorBuilder.build].
enum _Mode { everything, fromVersion, updatesOnly }

class MirrorBuilder {
  /// ניתן להזרקה לבדיקות. `null` = חיבור אמיתי שנפתח ונסגר בכל הכנה.
  final http.Client? httpClient;

  /// כמה גרסאות אחורה נשמרות כשאין מצב של המחשב השני.
  final int historyDepth;

  const MirrorBuilder({
    this.httpClient,
    this.historyDepth = LibraryMirrorExporter.defaultHistoryDepth,
  });

  /// מוריד ל-[destDir] את מה שהמחשב השני צריך.
  ///
  /// שלושה מסלולים:
  /// * [includeFullLibrary] — ספרייה מלאה ועוד היסטוריית עדכונים: מתאים
  ///   לכל מחשב, גם כזה שהשרשרת שלו נקטעה או שרוצים להחזיר לו ספרים.
  /// * יש מצב שמור עם גרסה — רק מה שחסר מהגרסה שלו. אפסטרים מוסיף בעצמו
  ///   את הספרייה המלאה כשאין אליה מסלול עדכונים, או כשהוא איטי בהרבה.
  /// * אין מצב — היסטוריית העדכונים בלבד, בלי הספרייה המלאה.
  /// מצב שמור בלי גרסה ידועה מנותב לספרייה המלאה: זה המסלול היחיד שיעבוד
  /// שם, ובלעדיו המשתמש היה נוסע עם כונן שלא עושה כלום.
  Future<MirrorBuildResult> build({
    required String destDir,
    bool includeFullLibrary = false,
    void Function(MirrorProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final status = await OfflineComputerStatus.readFrom(destDir);
    final version = status?.libraryVersion;
    final mode = includeFullLibrary || (status != null && version == null)
        ? _Mode.everything
        : version != null
            ? _Mode.fromVersion
            : _Mode.updatesOnly;

    final ownsHttp = httpClient == null;
    final http.Client client = httpClient ?? http.Client();
    final source = mode == _Mode.updatesOnly
        ? _UpdatesOnlyReleaseClient(httpClient: client)
        : GithubLibraryReleaseClient(httpClient: client);
    final exporter = LibraryMirrorExporter(
      client: source,
      httpClient: client,
      historyDepth: historyDepth,
    );

    var progress = const MirrorProgress(phase: MirrorPhase.preparing);
    void report(MirrorProgress next) {
      progress = next;
      onProgress?.call(next);
    }

    report(progress);
    try {
      final changed = await exporter.export(
        destDir: destDir,
        // כמו בזרימת העדכון: המחשב השני לא יתכנן לגרסת ניסיון.
        allowPrerelease: false,
        fromVersion: mode == _Mode.fromVersion ? version : null,
        onStage: (stage) => ErrorLog.instance.record('הכנת כונן: $stage'),
        onWarning: (w) => ErrorLog.instance.record('הכנת כונן: $w'),
        onAssetProgress: (done, total) => report(MirrorProgress(
          phase: MirrorPhase.downloading,
          doneBytes: progress.doneBytes,
          totalBytes: progress.totalBytes,
          doneFiles: done,
          totalFiles: total,
        )),
        onBytesProgress: (done, total) => report(MirrorProgress(
          phase: MirrorPhase.downloading,
          doneBytes: done,
          totalBytes: total,
          doneFiles: progress.doneFiles,
          totalFiles: progress.totalFiles,
        )),
        isCancelled: isCancelled,
      );
      if (!changed) {
        return MirrorBuildResult(
          upToDate: true,
          includesFullLibrary: false,
          coversOtherComputer: true,
          status: status,
        );
      }
      report(MirrorProgress(
        phase: MirrorPhase.checking,
        doneBytes: progress.doneBytes,
        totalBytes: progress.totalBytes,
        doneFiles: progress.doneFiles,
        totalFiles: progress.totalFiles,
      ));
      return await _inspect(destDir, status);
    } catch (e, stack) {
      if (e is MirrorBuildException) rethrow;
      if (isCancelled?.call() == true || e is PatchDownloadCancelled) {
        throw const MirrorBuildCancelled();
      }
      ErrorLog.instance.recordError(e, stack);
      throw MirrorBuildException(_messageFor(e));
    } finally {
      exporter.dispose();
      source.dispose();
      if (ownsHttp) client.close();
    }
  }

  /// קורא את הכונן **דרך אותו לקוח שהמחשב השני ישתמש בו**, ומתכנן ממנו
  /// מהגרסה השמורה. כך "מוכן" פירושו מה שהמחשב השני יראה בפועל, ולא מה
  /// שחשבנו שהורדנו.
  Future<MirrorBuildResult> _inspect(
    String destDir,
    OfflineComputerStatus? status,
  ) async {
    final mirror = LocalMirrorLibraryReleaseClient(mirrorDir: destDir);
    try {
      final releases = await mirror.fetchReleases();
      final hasFull =
          releases.any((r) => r.assets.any((a) => a.isFullDbArchive));
      final version = status?.libraryVersion;
      bool? covers;
      if (version != null) {
        final discovery = await LibraryUpdateDiscovery(client: mirror)
            .discover(allowPrerelease: false);
        final plan = const LibraryUpdatePlanner().plan(
          localVersion: version,
          hasLocalVersionMeta: true,
          latestVersion: discovery.latestVersion,
          edges: discovery.edges,
          latestFullDbAsset: discovery.latestFullDbAsset,
          fullDbReleaseTag: discovery.fullDbReleaseTag,
          latestFullDbVersion: discovery.latestFullDbVersion,
          latestContentTag: discovery.latestContentTag,
          blockingSchemaVersion: discovery.blockingSchemaVersion,
          blockingPatchFormatVersion: discovery.blockingPatchFormatVersion,
        );
        covers = switch (plan.kind) {
          LibraryUpdatePlanKind.none || LibraryUpdatePlanKind.delta => true,
          LibraryUpdatePlanKind.fullDownload => plan.fullDbAsset != null,
          LibraryUpdatePlanKind.blocked => false,
        };
        if (!covers) {
          ErrorLog.instance.record('הכנת כונן: המחשב השני לא יתעדכן מהכונן: '
              '${plan.kind.name} ${plan.reason ?? ''}');
        }
      } else if (status != null) {
        covers = hasFull;
      }
      return MirrorBuildResult(
        upToDate: false,
        includesFullLibrary: hasFull,
        coversOtherComputer: covers,
        status: status,
      );
    } finally {
      mirror.dispose();
    }
  }

  static String _messageFor(Object e) {
    if (_isDiskSpace(e)) {
      return 'אין מספיק מקום פנוי בכונן. פנו מקום ונסו שוב — '
          'מה שכבר ירד נשמר.';
    }
    if (e is SocketException ||
        e is http.ClientException ||
        e is TimeoutException ||
        e is HandshakeException) {
      return 'אין חיבור לאינטרנט, או שהשרת לא הגיב. נסו שוב — '
          'מה שכבר ירד נשמר.';
    }
    if (e is FileSystemException) {
      return 'לא הצלחנו לכתוב לכונן. ודאו שהוא מחובר ושאפשר לכתוב אליו, '
          'ונסו שוב.';
    }
    return 'הכנת הכונן נכשלה. נסו שוב — מה שכבר ירד נשמר.';
  }

  /// ההודעה של אפסטרים נושאת נתיב, ולכן אינה מוצגת כמות שהיא אלא מזוהה
  /// לפי הניסוח. הוא בעברית כי האפליקציה לא מחליפה את שפת אפסטרים;
  /// ניסוח שישתנה שם רק יחזיר את ההודעה הכללית.
  static bool _isDiskSpace(Object e) =>
      e is StateError && e.message.contains('מקום פנוי');
}

/// מקור שמסתיר את הספרייה המלאה. בלי מצב של המחשב השני, הייצוא של
/// אפסטרים נושא תמיד עותק של הספרייה המלאה (~1.5GB); כאן היא נעלמת
/// מהרשימה, וכך נשארת רק היסטוריית העדכונים — כולל החלקים שלה כשהיא
/// מפורסמת מפוצלת, שאחרת היו יורדים כקבצים בודדים.
class _UpdatesOnlyReleaseClient extends GithubLibraryReleaseClient {
  _UpdatesOnlyReleaseClient({super.httpClient});

  @override
  Future<List<LibraryRelease>> fetchReleases() async => [
        for (final r in await super.fetchReleases())
          LibraryRelease(
            tag: r.tag,
            isPrerelease: r.isPrerelease,
            isDraft: r.isDraft,
            publishedAt: r.publishedAt,
            assets: [
              for (final a in r.assets)
                if (!_isFullLibraryAsset(a.name)) a,
            ],
          ),
      ];

  static bool _isFullLibraryAsset(String name) =>
      name == ReleaseAsset.fullDbArchiveName ||
      name.startsWith('${ReleaseAsset.fullDbArchiveName}.');
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_updater.dart';
import '../services/error_report.dart';
import '../theme.dart';
import 'format.dart';
import 'icon_badge.dart';

/// הודעה על גרסה חדשה של **התוכנה**.
///
/// הניסוח מפריד במפורש בין התוכנה לספרייה: מי שיקרא כאן "עדכון" סתם
/// יחשוב שמדובר בספרים, וילחץ בציפייה להורדה של ספרייה. לכן המילה
/// "התוכנה" מופיעה בכותרת ובכפתור.
class AppUpdateCard extends StatelessWidget {
  final AppRelease release;
  final VoidCallback onInstall;

  const AppUpdateCard({
    super.key,
    required this.release,
    required this.onInstall,
  });

  @override
  Widget build(BuildContext context) => TintedCard(
        color: AppColors.accent,
        soft: AppColors.accentSoft,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              const IconBadge(
                icon: Icons.system_update_alt_rounded,
                color: AppColors.accent,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'יש גרסה חדשה של התוכנה',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      release.sizeBytes > 0
                          ? 'גרסה ${release.version} • '
                              '${formatBytes(release.sizeBytes)} להורדה. '
                              'ההורדה נוגעת בתוכנה בלבד.'
                          : 'גרסה ${release.version}. ההורדה נוגעת בתוכנה בלבד.',
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: onInstall,
                child: const Text('עדכון התוכנה'),
              ),
            ],
          ),
        ),
      );
}

/// מוריד את הגרסה החדשה מול דיאלוג חוסם. מחזיר `true` אם ההורדה נכשלה,
/// ו-`false` אם המשתמש ביטל — ביטול אינו תקלה ואינו מקפיץ הודעה.
///
/// בהצלחה הוא **אינו חוזר**: הפורש עולה והאפליקציה נסגרת מתחתיו.
///
/// ‏[updater] ניתן להחלפה רק בשביל בדיקות — ההורדה האמיתית סוגרת את
/// התהליך.
Future<bool> showAppUpdateDialog(
  BuildContext context,
  AppRelease release, {
  AppUpdater updater = const AppUpdater(),
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          _AppUpdateDialog(release: release, updater: updater),
    ) ??
    false;

class _AppUpdateDialog extends StatefulWidget {
  final AppRelease release;
  final AppUpdater updater;

  const _AppUpdateDialog({required this.release, required this.updater});

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
  StreamSubscription<double>? _download;
  double? _progress;

  /// הדיאלוג נסגר פעם אחת בלבד. זרם שנכשל שולח שגיאה **ואז** סיום, וה-State
  /// עדיין mounted בזמן אנימציית הסגירה — pop שני היה סוגר את המסך שמתחת.
  var _closed = false;

  @override
  void initState() {
    super.initState();
    // כל סיום של ההזרמה הוא כשל — ראו AppUpdater.install.
    _download = widget.updater.install(widget.release).listen(
      (value) {
        if (!_closed && mounted) setState(() => _progress = value);
      },
      // המשתמש רואה רק "העדכון לא הושלם"; הסיבה (למשל hash שלא תאם)
      // נשמרת ביומן, כדי שדיווח תקלה יגיד מה קרה באמת.
      onError: (Object error, StackTrace stack) {
        ErrorLog.instance.recordError(error, stack);
        _close(true);
      },
      onDone: () => _close(true),
    );
  }

  @override
  void dispose() {
    unawaited(_download?.cancel());
    super.dispose();
  }

  void _close(bool failed) {
    if (_closed || !mounted) return;
    _closed = true;
    unawaited(_download?.cancel());
    Navigator.of(context).pop(failed);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('מוריד את הגרסה החדשה'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('התוכנה תיסגר ותיפתח מחדש לבד בעוד רגע.'),
              const SizedBox(height: 20),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 8,
                ),
              ),
            ],
          ),
        ),
        // בלי היציאה הזו חיבור שנתקע באמצע היה משאיר את המשתמש מול
        // פס התקדמות קפוא בלי שום דרך לסגור אותו.
        actions: [
          TextButton(
            onPressed: () => _close(false),
            child: const Text('ביטול'),
          ),
        ],
      );
}

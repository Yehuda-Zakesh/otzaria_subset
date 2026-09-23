import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_updater.dart';
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
Future<bool> showAppUpdateDialog(
  BuildContext context,
  AppRelease release,
) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _AppUpdateDialog(release: release),
    ) ??
    false;

class _AppUpdateDialog extends StatefulWidget {
  final AppRelease release;

  const _AppUpdateDialog({required this.release});

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
  StreamSubscription<double>? _download;
  double? _progress;

  @override
  void initState() {
    super.initState();
    // כל סיום של ההזרמה הוא כשל — ראו AppUpdater.install.
    _download = const AppUpdater().install(widget.release).listen(
          (value) => setState(() => _progress = value),
          onError: (Object _) => _fail(),
          onDone: _fail,
        );
  }

  @override
  void dispose() {
    unawaited(_download?.cancel());
    super.dispose();
  }

  void _fail() {
    if (mounted) Navigator.of(context).pop(true);
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
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('ביטול'),
          ),
        ],
      );
}

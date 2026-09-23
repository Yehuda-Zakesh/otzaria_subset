import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../services/error_report.dart';
import '../services/mirror_builder.dart';
import '../theme.dart';
import 'format.dart';
import 'icon_badge.dart';

/// כרטיס "הכנת כונן למחשב בלי אינטרנט". שני הצדדים באותו כרטיס, כי
/// אותו משתמש עומד פעם מול זה ופעם מול זה: במחשב המנותק שומרים את
/// מצבו לכונן, ובמחשב המקוון מורידים לכונן בדיוק את מה שחסר לו.
class OfflineDriveCard extends StatefulWidget {
  /// הספרייה של המחשב הזה — ממנה נקרא המצב שנשמר לכונן.
  final String? libraryDbPath;

  /// תיקייה להציע קודם, בדרך כלל תיקיית העדכונים שכבר נבחרה.
  final String? suggestedFolder;

  /// ניתן להזרקה לבדיקות.
  final MirrorBuilder builder;

  const OfflineDriveCard({
    super.key,
    required this.libraryDbPath,
    this.suggestedFolder,
    this.builder = const MirrorBuilder(),
  });

  @override
  State<OfflineDriveCard> createState() => _OfflineDriveCardState();
}

class _OfflineDriveCardState extends State<OfflineDriveCard> {
  String? _folder;
  OfflineComputerStatus? _status;
  bool _includeFull = false;

  bool _running = false;
  bool _cancelled = false;
  MirrorProgress? _progress;

  /// שורת התוצאה האחרונה, ואם היא אזהרה.
  String? _message;
  bool _messageIsWarning = false;

  @override
  void dispose() {
    // יציאה מהמסך עוצרת את ההורדה; מה שירד נשמר ויימשך בפעם הבאה.
    _cancelled = true;
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final dir = await getDirectoryPath(
      initialDirectory: _folder ?? widget.suggestedFolder,
      confirmButtonText: 'בחירה',
    );
    if (dir == null || !mounted) return;
    final status = await OfflineComputerStatus.readFrom(dir);
    if (!mounted) return;
    setState(() {
      _folder = dir;
      _status = status;
      _message = null;
    });
  }

  Future<void> _build() async {
    final folder = _folder;
    if (folder == null || _running) return;
    // המצב נקרא שוב: ייתכן שהכונן הוחלף מאז שנבחרה התיקייה.
    final status = await OfflineComputerStatus.readFrom(folder);
    if (!mounted) return;
    setState(() {
      _status = status;
      _running = true;
      _cancelled = false;
      _progress = null;
      _message = null;
    });
    String message;
    var warning = false;
    try {
      final result = await widget.builder.build(
        destDir: folder,
        includeFullLibrary: _includeFull,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        isCancelled: () => _cancelled,
      );
      (message, warning) = _describe(result);
    } on MirrorBuildCancelled {
      message = 'ההכנה בוטלה. מה שכבר ירד נשמר, והפעם הבאה תמשיך ממנו.';
      warning = true;
    } on MirrorBuildException catch (e) {
      message = e.message;
      warning = true;
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _message = message;
      _messageIsWarning = warning;
    });
  }

  (String, bool) _describe(MirrorBuildResult result) {
    if (result.upToDate) {
      return ('המחשב השני כבר מעודכן — אין מה להעביר אליו.', false);
    }
    if (result.coversOtherComputer == false) {
      return (
        'הכונן לא יספיק למחשב השני: הוא צריך את הספרייה המלאה. '
            'סמנו "לכלול את הספרייה המלאה" והכינו שוב.',
        true,
      );
    }
    const next = 'חברו אותו למחשב השני, ובהגדרות שם בחרו "עדכונים מתיקייה" '
        'ואת התיקייה הזו.';
    if (result.coversOtherComputer == null && !result.includesFullLibrary) {
      return (
        'הכונן מוכן. $next אם המחשב השני לא עודכן זמן רב, ייתכן שיידרש '
            'לכלול גם את הספרייה המלאה.',
        false,
      );
    }
    return ('הכונן מוכן. $next', false);
  }

  Future<void> _saveStatus() async {
    final dir = await getDirectoryPath(
      initialDirectory: _folder ?? widget.suggestedFolder,
      confirmButtonText: 'שמירה',
    );
    if (dir == null || !mounted) return;
    String message;
    var warning = false;
    try {
      final status = OfflineComputerStatus.capture(widget.libraryDbPath);
      await status.writeTo(dir);
      message = status.libraryVersion == null
          ? 'המצב נשמר. לא נמצאה כאן ספרייה שאפשר לעדכן, ולכן הכונן יוכן '
              'עם הספרייה המלאה.'
          : 'המצב נשמר. חברו את הכונן למחשב עם אינטרנט ובחרו בו '
              '"הכנת הכונן".';
    } catch (e, stack) {
      ErrorLog.instance.recordError(e, stack);
      message = 'לא הצלחנו לשמור לכונן. ודאו שהוא מחובר ושאפשר לכתוב אליו.';
      warning = true;
    }
    if (!mounted) return;
    setState(() {
      _message = message;
      _messageIsWarning = warning;
      // אם זו אותה תיקייה, המצב שעליה השתנה עכשיו.
      if (dir == _folder) _status = null;
    });
    if (dir == _folder) {
      final fresh = await OfflineComputerStatus.readFrom(dir);
      if (mounted) setState(() => _status = fresh);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const IconBadge(icon: Icons.usb_rounded, color: AppColors.seed),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'הכנת כונן למחשב בלי אינטרנט',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'במחשב שבלי אינטרנט שומרים את מצבו לכונן. במחשב הזה בוחרים את '
              'הכונן, ומורידים אליו בדיוק את העדכונים שחסרים שם.',
              style: muted,
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const IconBadge(
                icon: Icons.folder_open_rounded,
                color: AppColors.seed,
              ),
              title: Text(_folder ?? 'לא נבחר כונן'),
              subtitle: _folder == null ? null : Text(_statusLine()),
              trailing: TextButton(
                onPressed: _running ? null : _pickFolder,
                child: const Text('בחירה'),
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _includeFull,
              onChanged: _running
                  ? null
                  : (v) => setState(() => _includeFull = v ?? false),
              title: const Text('לכלול את הספרייה המלאה'),
              subtitle: const Text(
                'כ-1.5GB. נדרש כשהמחשב השני לא עודכן זמן רב, '
                'או כדי להחזיר אליו ספרים שנמחקו.',
              ),
            ),
            const SizedBox(height: 8),
            if (_running) ..._progressRows(theme) else _actions(),
            if (_message case final message?) ...[
              const SizedBox(height: 12),
              _MessageLine(text: message, warning: _messageIsWarning),
            ],
          ],
        ),
      ),
    );
  }

  String _statusLine() {
    final status = _status;
    if (status == null) {
      return 'לא נמצא על הכונן מצב של המחשב השני — יורדו כל העדכונים '
          'הזמינים.';
    }
    final d = status.savedAt;
    final who = status.computerName.isEmpty
        ? 'המחשב השני'
        : 'המחשב "${status.computerName}"';
    final when = '${d.day}/${d.month}/${d.year}';
    return status.libraryVersion == null
        ? 'נמצא מצב של $who מ-$when. הספרייה שם לא ניתנת לעדכון, ולכן '
            'תורד הספרייה המלאה.'
        : 'נמצא מצב של $who מ-$when — יורד רק מה שחסר לו.';
  }

  Widget _actions() => Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: _folder == null ? null : _build,
            icon: const Icon(Icons.download_rounded),
            label: const Text('הכנת הכונן'),
          ),
          OutlinedButton.icon(
            onPressed: _saveStatus,
            icon: const Icon(Icons.save_alt_rounded),
            label: const Text('שמירת מצב המחשב הזה לכונן'),
          ),
        ],
      );

  List<Widget> _progressRows(ThemeData theme) {
    final progress = _progress;
    final String line;
    switch (progress?.phase) {
      case MirrorPhase.downloading:
        final total = progress!.totalBytes;
        line = total == null || total <= 0
            ? 'מוריד…'
            : 'הורדו ${formatBytes(progress.doneBytes)} '
                'מתוך ${formatBytes(total)}';
      case MirrorPhase.checking:
        line = 'בודק שהכונן שלם…';
      case MirrorPhase.preparing || null:
        line = 'בודק מה צריך להוריד…';
    }
    return [
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LinearProgressIndicator(
          value: progress?.fraction,
          minHeight: 8,
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(child: Text(line, style: theme.textTheme.bodyMedium)),
          TextButton(
            onPressed:
                _cancelled ? null : () => setState(() => _cancelled = true),
            child: const Text('ביטול'),
          ),
        ],
      ),
    ];
  }
}

class _MessageLine extends StatelessWidget {
  final String text;
  final bool warning;
  const _MessageLine({required this.text, required this.warning});

  @override
  Widget build(BuildContext context) {
    final color = warning ? AppColors.warm : AppColors.ok;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: warning ? AppColors.warmSoft : AppColors.okSoft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            warning ? Icons.info_outline_rounded : Icons.check_circle_rounded,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(color: AppColors.ink)),
          ),
        ],
      ),
    );
  }
}

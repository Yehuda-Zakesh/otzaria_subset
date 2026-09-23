import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/error_report.dart';
import '../theme.dart';

/// מסך הדיווח על תקלה.
///
/// ## למה שתי דרכים ולמה דווקא אלה
///
/// התוכנה מגיעה מגיטהאב, ולכן מי שמדווח כבר יודע לאן לפנות — פנייה
/// מוכנה מראש חוסכת לו רק את ההעתקה. אבל פתיחת פנייה דורשת חשבון, ולא
/// לכל אחד יש. לכן יש גם קובץ דיווח: הוא עומד בפני עצמו, אפשר לצרף
/// אותו לפנייה, ואין בו שום דבר שהמשתמש לא ראה על המסך לפני כן.
Future<void> showErrorReportDialog(
  BuildContext context, {
  String? libraryPath,
}) =>
    showDialog<void>(
      context: context,
      builder: (context) => _ErrorReportDialog(
        report: ErrorReport.now(libraryPath: libraryPath),
      ),
    );

class _ErrorReportDialog extends StatefulWidget {
  final ErrorReport report;

  const _ErrorReportDialog({required this.report});

  @override
  State<_ErrorReportDialog> createState() => _ErrorReportDialogState();
}

class _ErrorReportDialogState extends State<_ErrorReportDialog> {
  String? _status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.tint(context, AppColors.warm, AppColors.warmSoft),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(
          Icons.bug_report_rounded,
          color: AppTheme.readable(context, AppColors.warm),
        ),
      ),
      title: const Text('דיווח על תקלה'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'זה כל מה שנשלח. אין כאן שמות ספרים, אין תוכן מהספרייה, '
              'ונתיבים אישיים מוסתרים.',
            ),
            const SizedBox(height: 14),
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: SingleChildScrollView(
                // הדיווח טכני ובאנגלית ברובו, ולכן LTR ובגופן קבוע־רוחב:
                // ‏RTL היה מפזר נתיבים ומספרי שורה לכל עבר.
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: SelectableText(
                    widget.report.text,
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontFamilyFallback: ['monospace'],
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
            ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Text(
                _status!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('סגירה'),
        ),
        TextButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.save_alt_rounded, size: 18),
          label: const Text('שמירת קובץ דיווח'),
        ),
        FilledButton.icon(
          onPressed: _openIssue,
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: const Text('פתיחת פנייה בגיטהאב'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final location = await getSaveLocation(
      suggestedName: widget.report.fileName,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'קובץ טקסט', extensions: ['txt']),
      ],
    );
    if (location == null) return;
    try {
      final path = await widget.report.saveTo(location.path);
      _say('הדיווח נשמר: $path');
    } catch (e) {
      _say('שמירת הקובץ נכשלה: $e');
    }
  }

  /// מעתיק ללוח לפני הפתיחה: הפנייה שנפתחת בדפדפן מקוצצת בכוונה, וכך
  /// אפשר להדביק בה את הדיווח המלא בלי לחזור הנה.
  Future<void> _openIssue() async {
    await Clipboard.setData(ClipboardData(text: widget.report.text));
    final opened = await openInBrowser(widget.report.issueUri());
    _say(
      opened
          ? 'הדפדפן נפתח. הדיווח המלא הועתק — אפשר להדביק אותו בפנייה, '
              'או לצרף את הקובץ.'
          : 'לא הצלחנו לפתוח את הדפדפן. הדיווח הועתק ללוח, ואפשר לפתוח '
              'פנייה ידנית בכתובת $kIssueUrl',
    );
  }

  void _say(String message) {
    if (mounted) setState(() => _status = message);
  }
}

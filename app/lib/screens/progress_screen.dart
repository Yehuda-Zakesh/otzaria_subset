import 'package:flutter/material.dart';

import '../services/update_flow.dart';
import '../theme.dart';
import '../widgets/icon_badge.dart';

/// מסך התקדמות לפעולה ארוכה.
///
/// ## למה ארבע נקודות ולא שלבי המנוע
///
/// המנוע מדווח `preflight`, `schema`, `copy`, `hash`, `swap`… זה בדיוק
/// סוג המידע שאינו אמור להגיע למשתמש. כאן הוא רואה ארבע תחנות שהוא
/// מבין: מוריד, מכין, מחיל, מסיים.
class ProgressScreen extends StatelessWidget {
  final String title;
  final FlowProgress? progress;
  final String? error;
  final VoidCallback? onCancel;
  final VoidCallback? onClose;

  const ProgressScreen({
    super.key,
    required this.title,
    this.progress,
    this.error,
    this.onCancel,
    this.onClose,
  });

  static const List<({FlowStage stage, String label})> _steps = [
    (stage: FlowStage.downloading, label: 'מוריד'),
    (stage: FlowStage.rebuilding, label: 'מכין'),
    (stage: FlowStage.applying, label: 'מחיל'),
    (stage: FlowStage.done, label: 'מסיים'),
  ];

  /// כמה תחנות כבר עברו. שלבים שאינם תחנה בפני עצמה נספרים לתחנה
  /// שלפניהם, כדי שהפס לא יקפוץ אחורה.
  static int _reached(FlowStage stage) => switch (stage) {
        FlowStage.discovering || FlowStage.downloading => 0,
        FlowStage.extracting || FlowStage.rebuilding => 1,
        FlowStage.filtering || FlowStage.applying || FlowStage.verifying => 2,
        FlowStage.done => 3,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = error != null;
    final current = progress;
    final reached = current == null ? 0 : _reached(current.stage);
    final finished = current?.stage == FlowStage.done;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 28),
              if (failed)
                _ErrorCard(message: error!)
              else ...[
                _StepTrack(steps: _steps, reached: reached, finished: finished),
                const SizedBox(height: 24),
                // פס עבה ומעוגל — קל יותר לעין מפס דק סטנדרטי.
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: SizedBox(
                    height: 10,
                    child: LinearProgressIndicator(
                      value: current?.fraction,
                      backgroundColor: scheme.primary.withValues(alpha: 0.12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(current?.message ?? 'מתחיל…'),
              ],
              const SizedBox(height: 28),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (!failed && !finished && onCancel != null)
                    TextButton(onPressed: onCancel, child: const Text('ביטול')),
                  if ((failed || finished) && onClose != null)
                    FilledButton(
                      onPressed: onClose,
                      child: const Text('סגור'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// מסלול התחנות: נקודות מחוברות בקו, כדי שהמשתמש יראה דרך ולא רק רשימה.
class _StepTrack extends StatelessWidget {
  final List<({FlowStage stage, String label})> steps;
  final int reached;
  final bool finished;

  const _StepTrack({
    required this.steps,
    required this.reached,
    required this.finished,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Row(
          children: [
            for (var i = 0; i < steps.length; i++) ...[
              if (i > 0)
                Expanded(
                  child: Container(
                    height: 3,
                    color: i <= reached
                        ? scheme.primary
                        : scheme.outlineVariant.withValues(alpha: 0.6),
                  ),
                ),
              _StepDot(
                done: i < reached || finished,
                active: i == reached && !finished,
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (var i = 0; i < steps.length; i++)
              Expanded(
                child: Text(
                  steps[i].label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: i == reached && !finished
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: i < reached || finished
                        ? scheme.primary
                        : i == reached
                            ? AppTheme.readable(context, AppColors.accent)
                            : scheme.outline,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// נקודה בודדת במסלול. השלב הפעיל מקבל זוהר עדין כדי שיהיה ברור ש"כאן עכשיו".
class _StepDot extends StatelessWidget {
  final bool done;
  final bool active;

  const _StepDot({required this.done, required this.active});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (done) {
      return CircleAvatar(
        radius: 13,
        backgroundColor: scheme.primary,
        child: Icon(
          Icons.check_rounded,
          size: 16,
          color: scheme.onPrimary,
        ),
      );
    }
    if (active) {
      return Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppTheme.readable(context, AppColors.accent),
          boxShadow: [
            BoxShadow(
              color: AppTheme.readable(context, AppColors.accent)
                  .withValues(alpha: 0.28),
              blurRadius: 10,
              spreadRadius: 2,
            ),
          ],
        ),
      );
    }
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: scheme.outlineVariant, width: 2),
      ),
    );
  }
}

/// מצב שגיאה — כרטיס אדום רך, לא רק אייקון בודד באמצע המסך.
class _ErrorCard extends StatelessWidget {
  final String message;

  const _ErrorCard({required this.message});

  @override
  Widget build(BuildContext context) => TintedCard(
        color: AppColors.danger,
        soft: AppColors.dangerSoft,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const IconBadge(
                icon: Icons.error_outline_rounded,
                color: AppColors.danger,
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      );
}

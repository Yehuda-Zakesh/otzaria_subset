import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../theme.dart';
import '../widgets/format.dart';
import '../widgets/update_guard.dart';

/// מסך הפתיחה. מראה שלושה דברים ותו לא: כמה ספרים, כמה מקום, ומה המצב.
///
/// כל מה שמאחורי הקלעים — גרסאות, hash-ים, נתיבים, שלבי בנייה — אינו
/// מעניין את מי שרק רוצה ספרייה קטנה יותר, ולכן אינו כאן.
class HomeScreen extends StatelessWidget {
  final VoidCallback onChooseBooks;
  final VoidCallback onCheckUpdates;
  final String? updateNotice;
  final bool checking;

  const HomeScreen({
    super.key,
    required this.onChooseBooks,
    required this.onCheckUpdates,
    this.updateNotice,
    this.checking = false,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (!state.otzariaFound) return const _Empty();
    final stats = state.stats;

    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 40),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Hero(
                  books: stats?.bookCount,
                  bytes: state.libraryBytes,
                  status: checking
                      ? 'בודק עדכונים…'
                      : (updateNotice ?? 'הספרייה מעודכנת'),
                  highlight: !checking && updateNotice != null,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onChooseBooks,
                  icon: const Icon(Icons.tune_rounded),
                  label: const Text('בחירת ספרים'),
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: checking ? null : onCheckUpdates,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('בדיקת עדכונים'),
                ),
                if (state.pendingAcquisition.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  _PendingCard(count: state.pendingAcquisition.length),
                ],
                const SizedBox(height: 24),
                UpdateGuardBanner(
                  settings: state.otzariaUpdates,
                  onRecheck: () => unawaited(state.refreshOtzaria()),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// כרטיס הפתיחה — המספר הגדול, ומסביבו גרדיאנט.
class _Hero extends StatelessWidget {
  final int? books;
  final int bytes;
  final String status;
  final bool highlight;

  const _Hero({
    required this.books,
    required this.bytes,
    required this.status,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(32, 36, 32, 32),
        decoration: BoxDecoration(
          gradient: AppTheme.hero(context),
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: AppColors.seed.withValues(alpha: 0.28),
              blurRadius: 28,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'הספרייה שלך',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 17,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              textBaseline: TextBaseline.alphabetic,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              children: [
                Text(
                  books == null ? '—' : formatCount(books!),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 54,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'ספרים',
                  style: TextStyle(color: Colors.white, fontSize: 20),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _Pill(icon: Icons.sd_storage_rounded, text: formatBytes(bytes)),
                _Pill(
                  icon: highlight
                      ? Icons.download_rounded
                      : Icons.check_circle_rounded,
                  text: status,
                  strong: highlight,
                ),
              ],
            ),
          ],
        ),
      );
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool strong;

  const _Pill({required this.icon, required this.text, this.strong = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: strong ? 0.32 : 0.18),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: Colors.white),
            const SizedBox(width: 8),
            Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  gradient: AppTheme.hero(context),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.travel_explore_rounded,
                  size: 40,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'לא נמצאה ספריית אוצריא',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'צריך שאוצריא תהיה מותקנת ושהספרייה תהיה מורדת. אפשר גם '
                'להצביע על מיקום הספרייה ידנית במסך ההגדרות.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
}

/// ספרים שנבחרו ולא הגיעו — ראו §5 ב-AGENTS.md.
///
/// הניסוח נמנע מכל מונח פנימי: המשתמש צריך לדעת שחסרים לו ספרים ושצריך
/// לבנות שוב, לא מה זה patch ומה הוא נושא.
class _PendingCard extends StatelessWidget {
  final int count;

  const _PendingCard({required this.count});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.warm.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.schedule_rounded,
                  color: AppColors.warm,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  '$count ספרים שביקשת עדיין אינם כאן. הם יגיעו בפעם הבאה '
                  'שהספרייה תיבנה מחדש.',
                ),
              ),
            ],
          ),
        ),
      );
}

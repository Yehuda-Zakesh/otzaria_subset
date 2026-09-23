import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/app_updater.dart';
import '../theme.dart';
import '../widgets/app_update.dart';
import '../widgets/format.dart';
import '../widgets/icon_badge.dart';
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

  /// גרסה חדשה של התוכנה עצמה, אם יש. `null` = אין, או שהבדיקה נכשלה.
  final AppRelease? appUpdate;
  final VoidCallback onInstallAppUpdate;

  /// הבאת הספרים שממתינים — בנייה ממסד מלא עם הבחירה הנוכחית.
  final VoidCallback onFetchPending;

  const HomeScreen({
    required this.onFetchPending,
    super.key,
    required this.onChooseBooks,
    required this.onCheckUpdates,
    required this.onInstallAppUpdate,
    this.updateNotice,
    this.checking = false,
    this.appUpdate,
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
            constraints: const BoxConstraints(maxWidth: 760),
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
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: onChooseBooks,
                      icon: const Icon(Icons.tune_rounded),
                      label: const Text('בחירת ספרים'),
                    ),
                    OutlinedButton.icon(
                      // לפני המחיקה הראשונה אין מה לעדכן כאן — הספרייה עדיין
                      // של אוצריא, והיא מעדכנת אותה בעצמה.
                      onPressed:
                          checking || !state.hasSubset ? null : onCheckUpdates,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('בדיקת עדכונים'),
                    ),
                  ],
                ),
                if (appUpdate != null) ...[
                  const SizedBox(height: 24),
                  AppUpdateCard(
                    release: appUpdate!,
                    onInstall: onInstallAppUpdate,
                  ),
                ],
                if (state.pendingAcquisition.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  _PendingCard(
                    count: state.pendingAcquisition.length,
                    onFetch: onFetchPending,
                  ),
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

/// כרטיס הפתיחה — מספרי הספרים, גודל הספרייה, ומצב עדכון.
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
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 22),
        decoration: BoxDecoration(
          // הגרדיאנט של הפלטה, בטון־ביניים. זה המשטח הצבעוני **היחיד**
          // במסך, וזו הסיבה שהוא עדיין נקרא כמוקד בלי להיות כמעט־שחור.
          gradient: AppTheme.hero(context),
          borderRadius: BorderRadius.circular(28),
          boxShadow: AppShadows.strong,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.auto_stories_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'הספרייה שלך',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 26),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  books == null ? '—' : formatCount(books!),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 58,
                    fontWeight: FontWeight.w800,
                    height: 1,
                    letterSpacing: -1.8,
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    books == 1 ? 'ספר' : 'ספרים',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
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
          color: Colors.white.withValues(alpha: strong ? 0.26 : 0.15),
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
  final VoidCallback onFetch;

  const _PendingCard({required this.count, required this.onFetch});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              const IconBadge(
                icon: Icons.schedule_rounded,
                color: AppColors.warm,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  // עדכון רגיל לא יביא אותם לעולם (§5) — ולכן הכפתור, ולא
                  // הבטחה ל"פעם הבאה" שכמעט אינה מגיעה.
                  count == 1
                      ? 'ספר אחד שביקשת עדיין אינו כאן. כדי להביא אותו צריך '
                          'להוריד את הספרייה המלאה פעם אחת.'
                      : '${formatCount(count)} ספרים שביקשת עדיין אינם כאן. '
                          'כדי להביא אותם צריך להוריד את הספרייה המלאה פעם '
                          'אחת.',
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: onFetch,
                child: const Text('להביא עכשיו'),
              ),
            ],
          ),
        ),
      );
}

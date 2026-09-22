import 'package:flutter/material.dart';

import '../theme.dart';

/// ההבהרה שהתוכנה אינה קשורה לאוצריא.
///
/// ## למה זה לא רק נוסח משפטי
///
/// התוכנה משנה את קובץ הספרייה של אוצריא ומוחקת ממנו ספרים. משתמש
/// שיתקל אחר כך בבעיה יפנה באופן טבעי למי שכתב את אוצריא — ויקבל שם
/// אבחון שגוי, כי הם אינם יודעים שמשהו נגע במסד. ההבהרה מופיעה פעם
/// אחת בהתחלה, ושוב לפני כל מחיקה, בדיוק מהסיבה הזו.
const String kDisclaimer =
    'התוכנה הזו אינה חלק מאוצריא, אינה מפותחת על ידה ואינה קשורה אליה. '
    'היא משנה את קובץ הספרייה שבמחשב שלך, והשימוש בה הוא באחריותך '
    'בלבד. בכל תקלה שנובעת מהשימוש בה אין לפנות לצוות אוצריא.';

/// דיאלוג חוסם בהפעלה הראשונה. מחזיר `true` רק אם המשתמש אישר.
Future<bool> showDisclaimerDialog(BuildContext context) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.warm.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.info_outline_rounded, color: AppColors.warm),
      ),
      title: const Text('לפני שמתחילים'),
      content: const SizedBox(
        width: 460,
        child: Text(kDisclaimer),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('הבנתי, להמשיך'),
        ),
      ],
    ),
  );
  return accepted ?? false;
}

/// שורת ההבהרה הקבועה, למסך ההגדרות.
class DisclaimerFooter extends StatelessWidget {
  const DisclaimerFooter({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
        child: Text(
          kDisclaimer,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
      );
}

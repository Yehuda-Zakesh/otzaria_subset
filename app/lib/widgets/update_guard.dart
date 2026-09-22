import 'package:flutter/material.dart';
import 'package:otzaria_subset/otzaria_subset.dart';

/// ההנחיה המדויקת, לפי מסך ההגדרות של אוצריא.
const String kHowToDisable = 'באוצריא: הגדרות ← מערכת ← "עדכוני מערכת" ← '
    'לכבות את "עדכוני תוכנה וספרים". לחלופין לכבות רק את "סינכרון הספרייה '
    'באופן אוטומטי", או להעביר את "סינכרון ומצב רשת" ל"מנותק". אחרי '
    'השינוי יש לסגור את אוצריא כדי שההגדרה תיכתב לדיסק.';

/// האזהרה על עדכון הספרייה האוטומטי של אוצריא.
///
/// ## למה זה חוסם ולא רק מציק
///
/// אוצריא בודקת את הספרייה אחרי כל עדכון, וספרייה שחסרים בה ספרים
/// נכשלת בבדיקה הזו **בהכרח**. כל כשל מנותב אצלה להורדה מלאה שמחזירה
/// את הכול. לכן שום פעולה אינה מתחילה עד שהעדכון שם כבוי.
class UpdateGuardBanner extends StatelessWidget {
  final OtzariaUpdateSettings? settings;
  final VoidCallback onRecheck;

  const UpdateGuardBanner({
    super.key,
    required this.settings,
    required this.onRecheck,
  });

  @override
  Widget build(BuildContext context) {
    final current = settings;
    if (current == null) return const SizedBox.shrink();
    if (current.isDisabled) {
      return _tile(
        context,
        color: Colors.green,
        icon: Icons.verified_user_rounded,
        title: 'הכול מוגן',
        body: 'כדאי לבדוק שוב אחרי כל עדכון של אוצריא עצמה.',
      );
    }
    return _tile(
      context,
      color: Colors.red,
      icon: Icons.warning_amber_rounded,
      title: current.found
          ? 'הספרים שתמחק יחזרו — צריך לכבות משהו באוצריא'
          : 'לא הצלחנו לבדוק את ההגדרות של אוצריא',
      body: '${current.explanation}\n\n$kHowToDisable',
    );
  }

  Widget _tile(
    BuildContext context, {
    required Color color,
    required IconData icon,
    required String title,
    required String body,
  }) =>
      Card(
        color: color.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // תג אייקון צבעוני, כמו שאר סעיפי ההגדרות — לא רק אייקון בודד.
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(body),
                  ],
                ),
              ),
              TextButton(onPressed: onRecheck, child: const Text('בדוק שוב')),
            ],
          ),
        ),
      );
}

/// דיאלוג חוסם לפני הבנייה הראשונה.
///
/// מחזיר `true` רק כשהמשתמש בחר להמשיך בכל זאת — החלטה מודעת שלו ולא
/// ברירת מחדל.
Future<bool> showUpdateGuardDialog(
  BuildContext context,
  OtzariaUpdateSettings settings,
) async {
  final proceed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('אוצריא עדיין תוריד את הספרים בחזרה'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(settings.explanation),
            const SizedBox(height: 16),
            const Text(kHowToDisable),
            const SizedBox(height: 16),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('חזרה'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('הבנתי, להמשיך בכל זאת'),
        ),
      ],
    ),
  );
  return proceed ?? false;
}

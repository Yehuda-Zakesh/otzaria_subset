import 'package:flutter/material.dart';

import '../theme.dart';

/// תג אייקון קטן: ריבוע מלא בצבע הסעיף, ואייקון לבן עליו.
///
/// התג חוזר בחמישה מקומות, וקודם כל אחד צייר אותו בעצמו עם אטימות
/// משלו — ולכן אותו סעיף יצא בגוון אחר בכל מסך. הריבוע מלא ולא שקוף
/// כדי שיישאר קריא גם כשהוא יושב על כרטיס שכבר צבוע באותו גוון.
class IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;

  const IconBadge({super.key, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppTheme.readable(context, color),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(
          icon,
          color: Theme.of(context).brightness == Brightness.dark
              ? AppColors.ink
              : Colors.white,
        ),
      );
}

/// כרטיס בגוון רך — הודעה שצריך לשים לב אליה, אך לא אזהרה צועקת.
///
/// הרקע הוא הגוון הרך המכויל ולא הצבע באטימות נמוכה: ערבוב אטימות מעל
/// משטח לבן נתן בכל מסך גוון מעט אחר.
class TintedCard extends StatelessWidget {
  final Color color;
  final Color soft;
  final Widget child;

  const TintedCard({
    super.key,
    required this.color,
    required this.soft,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => Card(
        color: AppTheme.tint(context, color, soft),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: AppTheme.readable(context, color).withValues(alpha: 0.24),
          ),
        ),
        child: child,
      );
}

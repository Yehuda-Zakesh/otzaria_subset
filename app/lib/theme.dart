import 'package:flutter/material.dart';

/// הפלטה של התוכנה.
///
/// ## למה דווקא לא חום
///
/// זו **אינה** אוצריא, והיא נוגעת בקבצים שלה. משתמש שיחשוב שזו אוצריא
/// יניח שהיא אחראית למה שקורה כאן, ובדיוק כאן נמחקים ספרים. לכן הצבעים
/// רחוקים ככל האפשר מהחום־נייר של ספרייה תורנית: סגול־אינדיגו חי,
/// ומבטא טורקיז.
abstract final class AppColors {
  static const Color seed = Color(0xFF6C4CE0);
  static const Color accent = Color(0xFF00C9A7);
  static const Color warm = Color(0xFFFF7A59);

  /// הגרדיאנט של כרטיס הפתיחה. שתי נקודות בלבד — יותר מזה נראה רועש.
  static const List<Color> heroLight = [Color(0xFF7C5CFF), Color(0xFF3AC7E8)];
  static const List<Color> heroDark = [Color(0xFF4B32B8), Color(0xFF12708A)];
}

/// ערכות הנושא. פינות גדולות וכרטיסים שטוחים — השפה שהמשתמש מכיר
/// מאפליקציות שנכתבו בעשור הזה.
abstract final class AppTheme {
  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.seed,
      brightness: brightness,
    ).copyWith(tertiary: AppColors.accent);
    final dark = brightness == Brightness.dark;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          dark ? const Color(0xFF12101A) : const Color(0xFFF7F5FF),
      cardTheme: CardThemeData(
        elevation: 0,
        color: dark ? const Color(0xFF1C1928) : Colors.white,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF221E31) : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      ),
      dividerTheme: const DividerThemeData(thickness: 0.6, space: 1),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        borderRadius: BorderRadius.circular(8),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }

  /// הגרדיאנט לפי מצב התצוגה.
  static LinearGradient hero(BuildContext context) => LinearGradient(
        begin: AlignmentDirectional.topStart,
        end: AlignmentDirectional.bottomEnd,
        colors: Theme.of(context).brightness == Brightness.dark
            ? AppColors.heroDark
            : AppColors.heroLight,
      );
}

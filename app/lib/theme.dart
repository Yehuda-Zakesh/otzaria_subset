import 'package:flutter/material.dart';

/// הפלטה של התוכנה.
///
/// ## למה דווקא לא חום
///
/// זו אינה אוצריא, והיא נוגעת בקבצים שלה. משתמש שיחשוב שזו אוצריא
/// יניח שהיא אחראית למה שקורה כאן, ובדיוק כאן נמחקים ספרים. לכן הצבעים
/// רחוקים מהחום־נייר של ספרייה תורנית: סגול־אינדיגו חי ומבטא טורקיז.
abstract final class AppColors {
  static const Color seed = Color(0xFF5E4AE6);
  static const Color accent = Color(0xFF2AC8B5);
  static const Color accentSoft = Color(0xFFDDFBF7);
  static const Color warm = Color(0xFFFF8C66);
  static const Color warmSoft = Color(0xFFFFE1D5);
  static const Color surface = Color(0xFFF9F7FF);
  static const Color surfaceAlt = Color(0xFFF1EEFB);
  static const Color panel = Color(0xFFEDE7FF);
  static const Color panelDeep = Color(0xFFE2DBFF);
  static const Color ink = Color(0xFF1C1830);
  static const Color inkSoft = Color(0xFF5F5A72);
  static const Color midnight = Color(0xFF11111A);

  static const List<Color> heroLight = [
    Color(0xFF5D4BE6),
    Color(0xFF7C6CEB),
  ];
  static const List<Color> heroDark = [
    Color(0xFF2B2156),
    Color(0xFF171A2F),
  ];
}

abstract final class AppShadows {
  static List<BoxShadow> soft = [
    BoxShadow(
      color: const Color(0xFF5E3BFF).withValues(alpha: 0.12),
      blurRadius: 20,
      spreadRadius: 0,
      offset: const Offset(0, 10),
    ),
  ];

  static List<BoxShadow> strong = [
    BoxShadow(
      color: const Color(0xFF1C1239).withValues(alpha: 0.18),
      blurRadius: 32,
      spreadRadius: 0,
      offset: const Offset(0, 18),
    ),
  ];
}

abstract final class AppTheme {
  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final baseScheme = ColorScheme.fromSeed(
      seedColor: AppColors.seed,
      brightness: brightness,
    ).copyWith(
      primary: AppColors.seed,
      secondary: AppColors.accent,
      tertiary: AppColors.accent,
      surface: dark ? const Color(0xFF171421) : AppColors.surface,
      surfaceContainerHighest:
          dark ? const Color(0xFF231D32) : const Color(0xFFF0EAFF),
      onSurface: dark ? const Color(0xFFF9F6FF) : AppColors.ink,
    );

    final textTheme = ThemeData(
      brightness: brightness,
      fontFamily: 'Segoe UI',
    ).textTheme.apply(
          bodyColor: dark ? const Color(0xFFF9F6FF) : AppColors.ink,
          displayColor: dark ? const Color(0xFFF9F6FF) : AppColors.ink,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: baseScheme,
      scaffoldBackgroundColor:
          dark ? const Color(0xFF120F1A) : const Color(0xFFF6F3FF),
      textTheme: textTheme.copyWith(
        headlineLarge: textTheme.headlineLarge?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.8,
        ),
        headlineMedium: textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        titleLarge: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        titleMedium: textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        bodyLarge: textTheme.bodyLarge?.copyWith(
          height: 1.45,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: dark ? const Color(0xFF1D1A2B) : Colors.white,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(26),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          elevation: 0,
          shadowColor: Colors.transparent,
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          foregroundColor: baseScheme.primary,
          side: BorderSide(
            color: dark
                ? baseScheme.primary.withValues(alpha: 0.45)
                : const Color(0xFFD9D2FF),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF221C30) : Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        hintStyle: TextStyle(
          color: dark ? Colors.white60 : AppColors.inkSoft,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(
            color: AppColors.accent,
            width: 1.5,
          ),
        ),
      ),
      dividerTheme: const DividerThemeData(thickness: 0.7, space: 1),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearTrackColor: baseScheme.primary.withValues(alpha: 0.12),
        circularTrackColor: baseScheme.primary.withValues(alpha: 0.12),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }

  static LinearGradient hero(BuildContext context) => LinearGradient(
        begin: AlignmentDirectional.topStart,
        end: AlignmentDirectional.bottomEnd,
        colors: Theme.of(context).brightness == Brightness.dark
            ? AppColors.heroDark
            : AppColors.heroLight,
      );
}

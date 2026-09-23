import 'package:flutter/material.dart';

/// הפלטה של התוכנה.
///
/// ## למה דווקא לא חום
///
/// זו אינה אוצריא, והיא נוגעת בקבצים שלה. משתמש שיחשוב שזו אוצריא
/// יניח שהיא אחראית למה שקורה כאן, ובדיוק כאן נמחקים ספרים. לכן הצבעים
/// רחוקים מהחום־נייר של ספרייה תורנית: אינדיגו רגוע ומבטא טורקיז.
///
/// ## למה אין כאן שחור
///
/// הזהות נשענת על **גוון**, לא על ניגודיות. משטח כהה־כמעט־שחור על רקע
/// כמעט־לבן קופץ לעין חזק מכל דבר אחר במסך, וגונב את תשומת הלב
/// מהמספרים ומהכפתורים. לכן הטווח כאן צר: רקע בהיר־עדין, משטחים לבנים,
/// ומשטח מודגש אחד בטון־ביניים.
///
/// ## למה לכל צבע יש שני גוונים
///
/// הגוון הכהה (`accent`, `warm`) עובר את סף הקריאות על לבן, והוא היחיד
/// שמותר בטקסט. הגוון הבהיר (`*Soft`) הוא למילוי בלבד. בלי ההפרדה הזו
/// חוזר הטורקיז הבהיר שהיה כאן כטקסט ולא היה קריא.
abstract final class AppColors {
  static const Color seed = Color(0xFF5D50C6);
  static const Color accent = Color(0xFF127E72);
  static const Color accentSoft = Color(0xFFE0F1EE);
  static const Color warm = Color(0xFFA2661F);
  static const Color warmSoft = Color(0xFFF6EADA);
  static const Color ok = Color(0xFF2F7D5F);
  static const Color okSoft = Color(0xFFE2F0E9);
  static const Color danger = Color(0xFFB23A2E);
  static const Color dangerSoft = Color(0xFFF7E5E2);
  static const Color ink = Color(0xFF242034);
  static const Color inkSoft = Color(0xFF5E5A70);

  /// הגרדיאנט של המשטח המודגש. טון־ביניים: לבן נקרא עליו בנוחות, והוא
  /// עדיין קרוב מספיק לשאר המסך כדי לא לחתוך אותו לשניים.
  static const List<Color> heroLight = [
    Color(0xFF6A5BD0),
    Color(0xFF5346BC),
  ];
  static const List<Color> heroDark = [
    Color(0xFF3C3370),
    Color(0xFF2A2549),
  ];
}

/// גוני המעטפת — הרקע, המשטח המרכזי וסרגל הצד.
///
/// הם תלויים בבהיר/כהה ולכן נפתרים מה-`context`. קודם הם היו קבועים
/// בתוך המסכים, ובמצב כהה נשאר רקע בהיר עם טקסט בהיר עליו.
class AppSurfaces {
  final Color canvas;
  final Color panel;
  final Color panelBorder;
  final Color rail;
  final Color railBorder;
  final Color railSelected;
  final Color railInk;
  final Color railInkSelected;

  const AppSurfaces._({
    required this.canvas,
    required this.panel,
    required this.panelBorder,
    required this.rail,
    required this.railBorder,
    required this.railSelected,
    required this.railInk,
    required this.railInkSelected,
  });

  static const AppSurfaces _light = AppSurfaces._(
    canvas: Color(0xFFF5F3FB),
    panel: Color(0xFFFFFFFF),
    panelBorder: Color(0xFFE9E5F6),
    rail: Color(0xFFEDE9F9),
    railBorder: Color(0xFFE2DCF2),
    railSelected: Color(0xFFDCD5F4),
    railInk: Color(0xFF4C4763),
    railInkSelected: Color(0xFF433897),
  );

  static const AppSurfaces _dark = AppSurfaces._(
    canvas: Color(0xFF131120),
    panel: Color(0xFF1B1828),
    panelBorder: Color(0xFF2A2540),
    rail: Color(0xFF201C31),
    railBorder: Color(0xFF2C2742),
    railSelected: Color(0xFF332C4E),
    railInk: Color(0xFFC6C0DC),
    railInkSelected: Color(0xFFBDB1F7),
  );

  static AppSurfaces of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;
}

/// צללים רכים. אטימות נמוכה בכוונה — צל כהה מתחת למשטח בהיר הוא עוד
/// קפיצת ניגודיות, ותפקידו כאן רק להפריד שכבות.
abstract final class AppShadows {
  static List<BoxShadow> soft = [
    BoxShadow(
      color: const Color(0xFF322A5C).withValues(alpha: 0.07),
      blurRadius: 18,
      spreadRadius: 0,
      offset: const Offset(0, 8),
    ),
  ];

  static List<BoxShadow> strong = [
    BoxShadow(
      color: const Color(0xFF2B2450).withValues(alpha: 0.12),
      blurRadius: 26,
      spreadRadius: 0,
      offset: const Offset(0, 14),
    ),
  ];
}

abstract final class AppTheme {
  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final surfaces = dark ? AppSurfaces._dark : AppSurfaces._light;
    final baseScheme = ColorScheme.fromSeed(
      seedColor: AppColors.seed,
      brightness: brightness,
    ).copyWith(
      primary: dark ? const Color(0xFFB3A7F2) : AppColors.seed,
      onPrimary: dark ? const Color(0xFF231C4A) : Colors.white,
      secondary: dark ? const Color(0xFF6FC9BC) : AppColors.accent,
      onSecondary: dark ? const Color(0xFF07332E) : Colors.white,
      tertiary: dark ? const Color(0xFF6FC9BC) : AppColors.accent,
      surface: surfaces.panel,
      surfaceContainerHighest:
          dark ? const Color(0xFF262136) : const Color(0xFFF0EDFA),
      onSurface: dark ? const Color(0xFFEDEAF6) : AppColors.ink,
      onSurfaceVariant: dark ? const Color(0xFFB0AAC4) : AppColors.inkSoft,
      outline: dark ? const Color(0xFF7C7691) : const Color(0xFF837D98),
      outlineVariant: dark ? const Color(0xFF3A3450) : const Color(0xFFDFDAEC),
      error: dark ? const Color(0xFFE79A91) : AppColors.danger,
    );

    final textTheme = ThemeData(
      brightness: brightness,
      fontFamily: 'Segoe UI',
    ).textTheme.apply(
          bodyColor: baseScheme.onSurface,
          displayColor: baseScheme.onSurface,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: baseScheme,
      scaffoldBackgroundColor: surfaces.canvas,
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
        color: surfaces.panel,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          // מסגרת דקה במקום צל: היא מפרידה כרטיס לבן מרקע בהיר בלי
          // להוסיף עוד כתם כהה למסך.
          side: BorderSide(color: surfaces.panelBorder),
        ),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
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
          side: BorderSide(color: baseScheme.outlineVariant),
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
        fillColor: dark ? const Color(0xFF231F33) : const Color(0xFFF3F1FA),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        hintStyle: TextStyle(color: baseScheme.onSurfaceVariant),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: baseScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: baseScheme.primary, width: 1.5),
        ),
      ),
      dividerTheme: DividerThemeData(
        thickness: 0.7,
        space: 1,
        color: baseScheme.outlineVariant,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearTrackColor: baseScheme.primary.withValues(alpha: 0.14),
        circularTrackColor: baseScheme.primary.withValues(alpha: 0.14),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
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

  /// מילוי רך לתג אייקון או לכרטיס מודגש.
  ///
  /// במצב בהיר יש גוון מוכן; במצב כהה הוא היה בהיר מדי מול משטח כהה,
  /// ולכן שם הוא נגזר מהצבע עצמו באטימות נמוכה.
  static Color tint(BuildContext context, Color color, Color soft) =>
      Theme.of(context).brightness == Brightness.dark
          ? color.withValues(alpha: 0.20)
          : soft;

  /// הגוון הקריא של צבע סמנטי.
  ///
  /// הגוונים הכהים של הפלטה מכוילים ללבן; על משטח כהה הם נבלעים, ולכן
  /// שם מוחזרת גרסה בהירה שלהם.
  static Color readable(BuildContext context, Color color) =>
      Theme.of(context).brightness == Brightness.dark
          ? Color.lerp(color, Colors.white, 0.55)!
          : color;
}

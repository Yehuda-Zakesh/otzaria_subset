import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset_app/theme.dart';
import 'package:otzaria_subset_app/widgets/format.dart';

/// עוטף כמו ש-`SubsetApp` עוטף: אותה ערכת נושא ו-RTL כפוי, כדי שהבדיקה
/// תראה את הווידג'ט כפי שהמשתמש רואה אותו ולא בברירת המחדל של Material.
Future<void> pumpInApp(
  WidgetTester tester,
  Widget child, {
  ThemeMode mode = ThemeMode.light,
}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: mode,
        builder: (context, child) => Directionality(
          textDirection: TextDirection.rtl,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: child),
      ),
    );

/// כפתור שפותח דיאלוג ושומר את מה שהוא החזיר.
class DialogLauncher<T> extends StatelessWidget {
  final Future<T> Function(BuildContext context) open;
  final void Function(T result) onResult;

  const DialogLauncher({super.key, required this.open, required this.onResult});

  @override
  Widget build(BuildContext context) => Center(
        child: TextButton(
          onPressed: () async => onResult(await open(context)),
          child: const Text('פתח'),
        ),
      );
}

/// כל טקסט שמוצג כרגע — בלי מונחים פנימיים (§13, §15 ב-AGENTS.md).
void expectNoInternalTerms(WidgetTester tester) {
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final value = text.data ?? text.textSpan?.toPlainText() ?? '';
    expect(hasInternalTerms(value), isFalse, reason: value);
  }
}

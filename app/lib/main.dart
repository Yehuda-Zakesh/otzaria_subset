import 'package:flutter/material.dart';
import 'screens/home_shell.dart';
import 'services/error_report.dart';
import 'state/app_settings.dart';
import 'state/app_state.dart';
import 'theme.dart';
export 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // לפני כל דבר אחר: תקלה בעלייה היא בדיוק זו שאין עליה מידע אחר.
  installErrorLogging();
  ErrorLog.instance.record('התוכנה עלתה');
  final store = await AppSettingsStore.open();
  final state = AppState(store);
  // האיתור קורא קופסת Hive וקבצים — אסינכרוני, ולכן לפני ה-runApp
  // כדי שהמסך הראשון כבר יידע אם נמצאה ספרייה.
  try {
    await state.relocate();
  } catch (error, stack) {
    // כשל כאן היה נבלע ב-PlatformDispatcher.onError, ו-runApp לא היה רץ
    // לעולם — חלון ריק בלי שום הסבר. עדיף לעלות כ"ספרייה לא נמצאה".
    ErrorLog.instance.recordError(error, stack);
  }
  runApp(SubsetApp(state: state));
}

/// נקודת הכניסה. כל הממשק בעברית, ולכן RTL נכפה ב-[MaterialApp.builder]
/// ולא דרך locale — אין כאן תרגומים, רק כיוון.
class SubsetApp extends StatelessWidget {
  final AppState state;

  const SubsetApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ספרייה חלקית לאוצריא',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        builder: (context, child) => Directionality(
          textDirection: TextDirection.rtl,
          child: child ?? const SizedBox.shrink(),
        ),
        home: AppScope(state: state, child: const HomeShell()),
      );
}

/// מעביר את [AppState] במורד העץ ומרענן את מי שמאזין.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope חסר מעל הווידג׳ט הזה');
    return scope!.notifier!;
  }
}

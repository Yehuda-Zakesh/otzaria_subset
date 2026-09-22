import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:otzaria_subset/otzaria_subset.dart';

import '../services/otzaria_install.dart';
import 'app_settings.dart';

/// מצב האפליקציה.
///
/// ## מה המשתמש רואה ומה לא
///
/// נתיבים, גרסאות סכמה, hash-ים ופרופילים הם פרטי הפעלה — הם יושבים
/// כאן מפני שהמנוע צריך אותם, ולא מגיעים למסך. מה שכן מגיע: כמה ספרים
/// יש, כמה מקום הם תופסים, ואם יש עדכון.
class AppState extends ChangeNotifier {
  final AppSettingsStore settingsStore;

  AppState(this.settingsStore)
      : _settings = settingsStore.load(),
        _profileStore = ProfileStore(settingsStore.profilesDir.path);

  AppSettings _settings;
  AppSettings get settings => _settings;

  final ProfileStore _profileStore;

  OtzariaInstall _install = const OtzariaInstall();
  OtzariaInstall get paths => _install;

  SubsetProfile? _profile;
  SubsetProfile? get profile => _profile;

  LibraryStats? _stats;
  LibraryStats? get stats => _stats;

  OtzariaUpdateSettings? _otzariaUpdates;
  OtzariaUpdateSettings? get otzariaUpdates => _otzariaUpdates;

  LibraryCatalog? _catalog;
  LibraryCatalog? get catalog => _catalog;

  String? _error;
  String? get error => _error;

  bool _busy = false;
  bool get busy => _busy;

  /// ספרים שהמשתמש בחר ולא התקבלו — ראו §5 ב-AGENTS.md.
  Set<int> _pendingAcquisition = const {};
  Set<int> get pendingAcquisition => _pendingAcquisition;

  /// האם נמצאה בכלל התקנה של אוצריא במחשב הזה.
  bool get otzariaFound => _install.libraryDbPath != null;

  /// האם הספרייה כבר נגזמה. מסד מלא שאוצריא הורידה אינו "ספרייה שלנו"
  /// עד שהמשתמש בחר וגזם.
  bool get hasSubset => _profile?.spec.isEmpty == false;

  SubsetSpec get spec => _profile?.spec ?? SubsetSpec.empty;

  /// מאתר מחדש את ההתקנה ואת הפרופיל. נקרא בעלייה ואחרי שינוי הגדרות.
  Future<void> relocate() async {
    _install = await const OtzariaInstallLocator().locate(
      overridePath: _settings.libraryDbPathOverride,
    );
    _otzariaUpdates = await const OtzariaInstallLocator().readUpdateSettings();
    _loadProfile();
    notifyListeners();
  }

  /// פרופיל אחד למחשב הזה. אין מסך בחירת מחשב — `MachineIdentity` מזהה
  /// לבד, והמשתמש לא אמור לדעת שהמושג קיים.
  void _loadProfile() {
    final identity = MachineIdentity.resolve();
    final registry = MachineRegistry(_profileStore.directory.path);
    final boundId = registry.profileIdFor(identity);
    final existing = boundId == null ? null : _profileStore.load(boundId);
    if (existing != null) {
      _profile = existing;
      return;
    }
    // מחשב שאינו רשום מקבל פרופיל ונקשר אליו מיד, אחרת הוא היה מקבל
    // פרופיל חדש בכל פתיחה.
    final created = _profileStore.create(identity.suggestedLabel);
    registry.bind(identity, created.id);
    _profile = created;
  }

  Future<void> saveSettings(AppSettings next) async {
    _settings = next;
    settingsStore.save(next);
    await relocate();
  }

  /// בדיקה חוזרת של הגדרות אוצריא בלבד, לפני כל פעולה שנוגעת בספרייה.
  Future<void> refreshOtzaria() async {
    _otzariaUpdates = await const OtzariaInstallLocator().readUpdateSettings();
    notifyListeners();
  }

  void setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }

  void setError(String? message) {
    _error = message;
    notifyListeners();
  }

  void setCatalog(LibraryCatalog? value) {
    _catalog = value;
    notifyListeners();
  }

  void setStats(LibraryStats? value) {
    _stats = value;
    notifyListeners();
  }

  void setPendingAcquisition(Set<int> value) {
    _pendingAcquisition = value;
    notifyListeners();
  }

  void saveProfile(SubsetProfile next) {
    _profile = next;
    _profileStore.save(next);
    notifyListeners();
  }

  void updateSpec(SubsetSpec spec) {
    final current = _profile;
    if (current == null) return;
    saveProfile(current.copyWith(spec: spec));
  }

  /// גודל הספרייה כפי שהיא עכשיו על הדיסק.
  int get libraryBytes {
    final path = _install.libraryDbPath;
    if (path == null) return 0;
    final file = File(path);
    return file.existsSync() ? file.lengthSync() : 0;
  }
}

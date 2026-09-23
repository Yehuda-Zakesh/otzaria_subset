import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:otzaria_subset/otzaria_subset.dart';

import '../services/error_report.dart';
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

  /// ספרים שהמשתמש בחר ולא התקבלו — ראו §5 ב-AGENTS.md. נשמרים בפרופיל,
  /// כי בזיכרון בלבד הם נעלמו בסגירה הראשונה, והספר נשכח לתמיד.
  ///
  /// ספר שהבחירה כבר אינה שומרת (המשתמש מחק את הקטגוריה שלו) אינו
  /// "ממתין" — "להביא עכשיו" היה מוריד בשבילו את הספרייה המלאה לחינם.
  Set<int> get pendingAcquisition {
    final pending = _profile?.pendingBookIds ?? const <int>{};
    final snapshot = catalogSnapshot;
    if (pending.isEmpty || snapshot == null) return pending;
    return pending.where((id) {
      final book = snapshot.bookById(id);
      // ספר שנוסף אחרי התצלום — אין לפי מה לפסול אותו.
      return book == null || specKeepsBook(snapshot, spec, book);
    }).toSet();
  }

  /// הקטלוג המלא כפי שנקרא לפני הגזימה — המקור היחיד לדעת מה נמחק
  /// ואפשר להחזיר. הספרייה הגזומה עצמה כבר אינה יודעת.
  LibraryCatalog? _snapshot;
  var _snapshotLoaded = false;

  LibraryCatalog? get catalogSnapshot {
    final id = _profile?.id;
    if (id == null) return null;
    if (!_snapshotLoaded) {
      _snapshot = _profileStore.loadCatalogSnapshot(id);
      _snapshotLoaded = true;
    }
    return _snapshot;
  }

  void saveCatalogSnapshot(LibraryCatalog catalog) {
    final id = _profile?.id;
    if (id == null) return;
    try {
      _profileStore.saveCatalogSnapshot(id, catalog);
    } catch (e) {
      // נקרא בשיא תפוסת הדיסק, באמצע בנייה. כשל כאן מוותר רק על
      // האפשרות להחזיר ספרים אחר כך — אסור שיפיל את הבנייה עצמה.
      ErrorLog.instance.record('שמירת רשימת הספרים נכשלה: $e');
      return;
    }
    _snapshot = catalog;
    _snapshotLoaded = true;
    notifyListeners();
  }

  /// לבדיקות בלבד: [relocate] מאתר את אוצריא האמיתית שבמחשב.
  @visibleForTesting
  void debugSetInstall(OtzariaInstall install) {
    _install = install;
    notifyListeners();
  }

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
    _snapshotLoaded = false;
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
      // התאמה שנפלה לשם המחשב (המזהה המתמיד אבד) נרשמת מחדש תחת המזהה,
      // אחרת שינוי שם עתידי של המחשב היה מאבד את הפרופיל.
      if (registry.allBindings()[identity.id] != existing.id) {
        registry.bind(identity, existing.id);
      }
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
    // בספרייה גזומה הטבלאות הגלובליות נשארות שלמות, והכיול מהקובץ מנפח
    // כל ספר. הכיול מהקטלוג המלא הוא הנכון.
    final snapshot =
        _profile?.categoriesPruned == true ? catalogSnapshot : null;
    _catalog = value != null && snapshot != null && snapshot.bytesPerLine > 0
        ? value.withBytesPerLine(snapshot.bytesPerLine)
        : value;
    notifyListeners();
  }

  void setStats(LibraryStats? value) {
    _stats = value;
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

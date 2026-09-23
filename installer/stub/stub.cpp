// ‏EXE ההפצה. בלחיצה הראשונה הוא פורש תיקייה אחת לצדו ומפעיל את
// התוכנה; בכל לחיצה אחרת הוא רק מפעיל אותה. אין התקנה, אין רישום
// ב-Windows ואין הרשאות מנהל — התיקייה יושבת היכן שהמשתמש שם את
// הקובץ, וזה גם מה שמאפשר לעדכון העצמי להחליף אותה בלי UAC.
//
// המטען הוא `.tar.xz` מודבק לסוף הקובץ. הפריסה עצמה נעשית ב-tar.exe
// שיושב ב-System32 מאז Windows 10 ונבנה עם liblzma — כלומר אין כאן
// מפרק משלנו, אין ספרייה חיצונית, וה-stub רק מעתיק בתים ומריץ.
//
// מצב שני: `--update <pid> <תיקייה>` — ממתין שהתהליך הנתון ייסגר, פורש
// בכפייה לתיקייה הנתונה ומפעיל מחדש. זה מה שהעדכון העצמי מריץ.

#include <windows.h>

#include <cstdint>
#include <string>

namespace {

constexpr wchar_t kFolder[] = L"OtzariaSubset";
constexpr wchar_t kAppExe[] = L"otzaria_subset_app.exe";
constexpr wchar_t kStamp[] = L"version.txt";
constexpr wchar_t kTitle[] = L"ספרייה חלקית לאוצריא";
constexpr char kMagic[8] = {'O', 'T', 'Z', 'S', 'U', 'B', '0', '2'};

// יושבת ב-32 הבתים האחרונים של הקובץ. ההיסט של המטען נגזר מגודל
// הקובץ ולא נשמר, כדי שהדבקה פשוטה (stub + מטען) תספיק.
#pragma pack(push, 1)
struct Footer {
  char magic[8];
  uint64_t payloadSize;
  char version[16];
};
#pragma pack(pop)

static_assert(sizeof(Footer) == 32, "החתימה חייבת להישאר 32 בתים");

[[noreturn]] void Fail(const wchar_t* message) {
  MessageBoxW(nullptr, message, kTitle, MB_ICONERROR | MB_OK | MB_SETFOREGROUND);
  ExitProcess(1);
}

constexpr wchar_t kBroken[] = L"הקובץ פגום. כדאי להוריד אותו שוב.";

std::wstring SelfPath() {
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD n = GetModuleFileNameW(nullptr, &path[0], static_cast<DWORD>(path.size()));
    if (n == 0) Fail(L"לא הצלחנו לזהות את מיקום הקובץ.");
    if (n < path.size()) {
      path.resize(n);
      return path;
    }
    path.resize(path.size() * 2);
  }
}

std::wstring DirName(const std::wstring& path) {
  const size_t slash = path.find_last_of(L"\\/");
  return slash == std::wstring::npos ? std::wstring(L".") : path.substr(0, slash);
}

std::wstring SystemFile(const wchar_t* name) {
  wchar_t dir[MAX_PATH] = {0};
  if (GetSystemDirectoryW(dir, MAX_PATH) == 0) Fail(L"לא הצלחנו לאתר את תיקיית המערכת.");
  return std::wstring(dir) + L"\\" + name;
}

std::wstring TempFile(const wchar_t* name) {
  wchar_t dir[MAX_PATH] = {0};
  if (GetTempPathW(MAX_PATH, dir) == 0) Fail(L"לא נמצאה תיקייה זמנית לכתיבה.");
  return std::wstring(dir) + name;
}

// ── המטען ─────────────────────────────────────────────────────────

// מעתיק את המטען מסוף הקובץ שלנו לקובץ זמני, במנות. בלי החזקה של
// המטען כולו בזיכרון — אין סיבה ש-stub של הפעלה יבקש מהמערכת עשרות
// מגהבייטים.
Footer CopyPayload(const std::wstring& self, const std::wstring& archive) {
  const HANDLE source = CreateFileW(self.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                                    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (source == INVALID_HANDLE_VALUE) Fail(L"לא הצלחנו לקרוא את הקובץ.");

  LARGE_INTEGER size{};
  GetFileSizeEx(source, &size);

  Footer footer{};
  LARGE_INTEGER at{};
  at.QuadPart = size.QuadPart - static_cast<LONGLONG>(sizeof(footer));
  DWORD read = 0;
  if (at.QuadPart <= 0 || !SetFilePointerEx(source, at, nullptr, FILE_BEGIN) ||
      !ReadFile(source, &footer, sizeof(footer), &read, nullptr) || read != sizeof(footer) ||
      memcmp(footer.magic, kMagic, sizeof(kMagic)) != 0) {
    CloseHandle(source);
    Fail(kBroken);
  }

  at.QuadPart -= static_cast<LONGLONG>(footer.payloadSize);
  if (at.QuadPart < 0 || !SetFilePointerEx(source, at, nullptr, FILE_BEGIN)) {
    CloseHandle(source);
    Fail(kBroken);
  }

  const HANDLE target = CreateFileW(archive.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                                    FILE_ATTRIBUTE_TEMPORARY, nullptr);
  if (target == INVALID_HANDLE_VALUE) {
    CloseHandle(source);
    Fail(L"לא הצלחנו לכתוב לתיקייה הזמנית.");
  }

  static unsigned char buffer[1 << 20];
  uint64_t left = footer.payloadSize;
  while (left > 0) {
    const DWORD want = static_cast<DWORD>(left < sizeof(buffer) ? left : sizeof(buffer));
    DWORD written = 0;
    if (!ReadFile(source, buffer, want, &read, nullptr) || read == 0 ||
        !WriteFile(target, buffer, read, &written, nullptr) || written != read) {
      CloseHandle(target);
      CloseHandle(source);
      Fail(kBroken);
    }
    left -= read;
  }
  CloseHandle(target);
  CloseHandle(source);
  return footer;
}

// ── גרסאות ────────────────────────────────────────────────────────

bool ParseVersion(const std::string& text, int out[3]) {
  int part = 0, value = 0;
  bool digit = false;
  for (const char c : text) {
    if (c >= '0' && c <= '9') {
      value = value * 10 + (c - '0');
      digit = true;
    } else if (c == '.') {
      if (!digit || part == 2) return false;
      out[part++] = value;
      value = 0;
      digit = false;
    } else {
      break;
    }
  }
  if (!digit || part != 2) return false;
  out[2] = value;
  return true;
}

// האם מה שבמטען חדש ממה שכבר פרוש שם.
//
// השוואה ולא אי-שוויון: אחרי עדכון עצמי התיקייה מחזיקה גרסה חדשה מזו
// שב-EXE הישן שנשאר לידה. לחיצה עליו חייבת רק להפעיל, לא להחזיר את
// המשתמש אחורה.
bool ShouldDeploy(const std::wstring& stampPath, const std::string& version) {
  const HANDLE file = CreateFileW(stampPath.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return true;
  char buffer[32] = {0};
  DWORD read = 0;
  ReadFile(file, buffer, sizeof(buffer) - 1, &read, nullptr);
  CloseHandle(file);

  int here[3], there[3];
  if (!ParseVersion(std::string(buffer, read), here)) return true;
  if (!ParseVersion(version, there)) return true;
  for (int i = 0; i < 3; i++) {
    if (there[i] != here[i]) return there[i] > here[i];
  }
  return false;
}

void WriteStamp(const std::wstring& path, const std::string& version) {
  const HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                                  FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  WriteFile(file, version.data(), static_cast<DWORD>(version.size()), &written, nullptr);
  CloseHandle(file);
}

// ── חלון ההמתנה ───────────────────────────────────────────────────

// הפרישה נמשכת שנייה־שתיים ואין בה מה להראות, אבל בלי שום סימן חיים
// המשתמש לוחץ שוב ושוב. חלון סטטי אחד, בלי מחלקת חלון משלנו.
HWND ShowSplash() {
  const int width = 380, height = 96;
  const HWND window = CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYOUTRTL, L"STATIC",
      L"\nפורש את הקבצים…\nזה קורה פעם אחת בלבד.",
      WS_POPUP | WS_BORDER | WS_VISIBLE | SS_CENTER,
      (GetSystemMetrics(SM_CXSCREEN) - width) / 2, (GetSystemMetrics(SM_CYSCREEN) - height) / 2,
      width, height, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (window != nullptr) {
    SendMessageW(window, WM_SETFONT, reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)),
                 TRUE);
    UpdateWindow(window);
  }
  return window;
}

// ממתין לתהליך ומטפל בינתיים בהודעות, כדי שחלון ההמתנה ייצבע ולא
// ייראה תקוע.
DWORD WaitPumping(HANDLE process, DWORD timeout) {
  for (;;) {
    const DWORD result = MsgWaitForMultipleObjects(1, &process, FALSE, timeout, QS_ALLINPUT);
    if (result != WAIT_OBJECT_0 + 1) return result;
    MSG message;
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
  }
}

// ── הרצה ──────────────────────────────────────────────────────────

HANDLE Start(const std::wstring& exe, std::wstring command, const wchar_t* workingDir,
             DWORD flags) {
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(exe.c_str(), &command[0], nullptr, nullptr, FALSE, flags, nullptr, workingDir,
                      &startup, &process)) {
    return nullptr;
  }
  CloseHandle(process.hThread);
  return process.hProcess;
}

void Extract(const std::wstring& archive, const std::wstring& target) {
  CreateDirectoryW(target.c_str(), nullptr);
  const std::wstring tar = SystemFile(L"tar.exe");
  const std::wstring command =
      L"\"" + tar + L"\" -xf \"" + archive + L"\" -C \"" + target + L"\"";

  const HWND splash = ShowSplash();
  const HANDLE process = Start(tar, command, target.c_str(), CREATE_NO_WINDOW);
  if (process == nullptr) Fail(L"לא נמצא tar.exe במערכת. צריך Windows 10 ומעלה.");
  WaitPumping(process, INFINITE);
  DWORD code = 1;
  GetExitCodeProcess(process, &code);
  CloseHandle(process);
  if (splash != nullptr) DestroyWindow(splash);
  if (code != 0)
    Fail(L"פרישת הקבצים נכשלה. ייתכן שאין הרשאת כתיבה לתיקייה או שאין מספיק מקום פנוי.");
}

[[noreturn]] void LaunchAndExit(const std::wstring& target) {
  const std::wstring exe = target + L"\\" + kAppExe;
  if (Start(exe, L"\"" + exe + L"\"", target.c_str(), 0) == nullptr)
    Fail(L"התוכנה נפרשה אבל לא הצלחנו להפעיל אותה. אפשר לפתוח אותה מתוך התיקייה.");
  ExitProcess(0);
}

// ‏--update <pid> <תיקייה>: ממתין שהתוכנה תיסגר לפני שמחליפים אותה
// מתחתיה. בלי ההמתנה הזו הקבצים נעולים והפרישה נכשלת באמצע.
bool ParseUpdateMode(DWORD* waitFor, std::wstring* target) {
  int count = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &count);
  if (argv == nullptr) return false;
  const bool update = count == 4 && wcscmp(argv[1], L"--update") == 0;
  if (update) {
    *waitFor = static_cast<DWORD>(_wtoi(argv[2]));
    *target = argv[3];
  }
  LocalFree(argv);
  return update;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  DWORD waitFor = 0;
  std::wstring target;
  const bool update = ParseUpdateMode(&waitFor, &target);

  // שתי הרצות במקביל היו כותבות לאותם קבצים בדיוק.
  const HANDLE mutex = CreateMutexW(nullptr, TRUE, L"Local\\OtzariaSubsetDeployer");
  if (mutex != nullptr && GetLastError() == ERROR_ALREADY_EXISTS) return 0;

  const std::wstring self = SelfPath();
  if (!update) target = DirName(self) + L"\\" + kFolder;
  const std::wstring stamp = target + L"\\" + kStamp;

  const std::wstring archive = TempFile(L"otzaria-subset-payload.tar.xz");
  const Footer footer = CopyPayload(self, archive);
  const std::string version(footer.version,
                            strnlen(footer.version, sizeof(footer.version)));

  if (update) {
    // בעדכון אין בדיקת גרסה: מי שהריץ אותנו כבר החליט, והוא זה שנסגר.
    if (waitFor != 0) {
      const HANDLE other = OpenProcess(SYNCHRONIZE, FALSE, waitFor);
      if (other != nullptr) {
        WaitPumping(other, 30000);
        CloseHandle(other);
      }
    }
  } else if (!ShouldDeploy(stamp, version)) {
    DeleteFileW(archive.c_str());
    LaunchAndExit(target);
  }

  Extract(archive, target);
  DeleteFileW(archive.c_str());
  WriteStamp(stamp, version);
  LaunchAndExit(target);
}

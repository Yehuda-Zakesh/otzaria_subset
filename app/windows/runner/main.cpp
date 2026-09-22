#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // ‏720p הוא מסך שלם בהרבה מחשבים — חלון בגודל הזה בולט מהמסך והתוכן
  // בצד אחד נחתך. הקובץ נשמר עם BOM כדי ש-MSVC יקרא את הכותרת העברית
  // כ-UTF-8 ולא לפי קידוד המערכת.
  Win32Window::Size size(1000, 640);
  if (!window.Create(
          L"ספרייה חלקית"
          L" לאוצריא",
          origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // ‏Win32Window מקבל גודל **לוגי** ומכפיל אותו ב-DPI, ולכן חלון שנראה
  // סביר במסך רגיל חורג מהמסך ב-125%/150% — ואז צד אחד של הממשק פשוט
  // אינו נגיש. התאמה לשטח העבודה עובדת בפיקסלים אמיתיים ולכן נכונה בכל
  // רמת הגדלה.
  RECT work_area;
  if (SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0)) {
    RECT frame;
    if (GetWindowRect(window.GetHandle(), &frame)) {
      const LONG work_width = work_area.right - work_area.left;
      const LONG work_height = work_area.bottom - work_area.top;
      const LONG frame_width = frame.right - frame.left;
      const LONG frame_height = frame.bottom - frame.top;
      const LONG width = frame_width < work_width ? frame_width : work_width;
      const LONG height =
          frame_height < work_height ? frame_height : work_height;
      MoveWindow(window.GetHandle(),
                 work_area.left + (work_width - width) / 2,
                 work_area.top + (work_height - height) / 2, width, height,
                 TRUE);
    }
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

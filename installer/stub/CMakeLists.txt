# ה-stub של ההפצה, וזה הכל. אין כאן כלי אריזה: את ה-tar.xz בונה
# ‏build.ps1 עם 7-Zip, ואת הפריסה עושה ה-tar.exe שבמערכת.
#
# ‏CMake ולא cl.exe ישיר, כדי שזה ייבנה עם אותו Visual Studio שממילא
# נדרש ל-flutter build windows, בלי להסתמך על vcvars ב-PATH.
cmake_minimum_required(VERSION 3.15)
project(otzaria_deployer CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# ‏CRT סטטי: ה-stub רץ לפני שנפרש משהו, ואסור לו לתלות ב-DLL שאולי
# אינו מותקן במחשב.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

# האייקון של האפליקציה, כדי שקובץ ההפצה לא ייראה כמו exe אנונימי.
# הנתיב נכתב מוחלט לתוך ה-rc, כי rc.exe פותר נתיבים יחסיים לפי תיקיית
# ההרצה ולא לפי מיקום הקובץ.
set(kIconPath "${CMAKE_CURRENT_SOURCE_DIR}/../../app/windows/runner/resources/app_icon.ico")
configure_file(stub.rc.in "${CMAKE_CURRENT_BINARY_DIR}/stub.rc" @ONLY)

add_executable(otzaria_stub WIN32 stub.cpp "${CMAKE_CURRENT_BINARY_DIR}/stub.rc")
# ‏/utf-8: המקור והמחרוזות בעברית, ובלי הדגל MSVC קורא אותם כ-ANSI.
target_compile_options(otzaria_stub PRIVATE /utf-8 /W4)

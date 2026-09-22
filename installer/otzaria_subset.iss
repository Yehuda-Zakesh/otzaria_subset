; סקריפט Inno Setup לאפליקציית "ספרייה חלקית לאוצריא".
;
; זו אינה התקנה אלא **פרישה ניידת**: ה-EXE היחיד שמתפרסם פורש תיקייה
; אחת לידו ומפעיל אותה. אין Program Files, אין רישום ב-Windows ואין
; הסרה — מה שמשאיר את העדכון העצמי בלי UAC, כי התיקייה היא של המשתמש.
;
; MyAppVersion מגיע תמיד מ-/DMyAppVersion בשורת הפקודה (ה-workflow מזרים
; אותו מה-pubspec אחרי ה-bump) — במתכוון אין #define ברירת מחדל כאן,
; כדי שקומפילציה בלי /D תיכשל בקול רם במקום לייצר גרסה שקרית.
#define MyAppName "ספרייה חלקית לאוצריא"
#define MyAppPublisher "Otzaria"
#define MyAppExeName "otzaria_subset_app.exe"
; שם התיקייה הנפרשת. באנגלית במכוון: הנתיב הזה עובר בשורת הפקודה של
; העדכון העצמי (/DIR=), ו-ASCII בלי רווחים לא נשבר שם.
#define MyAppFolder "OtzariaSubset"

[Setup]
; GUID קבוע לאפליקציה הזו — לא לשנות בין גרסאות.
AppId={{7B7C7B9A-3D9B-4E9C-9E9B-6E0D6D9B7C21}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
; ‏{src} היא התיקייה שממנה הורץ ה-EXE — כלומר התיקייה נפרשת לידו.
DefaultDirName={src}\{#MyAppFolder}
; בלי זה הרצה שנייה הייתה נזכרת בתיקייה ישנה במקום לפרוש ליד עצמה.
UsePreviousAppDir=no
; אין הרשאות מנהל: התיקייה יושבת אצל המשתמש, והעדכון העצמי חייב
; להצליח בלי שיקפוץ UAC בכל גרסה.
PrivilegesRequired=lowest
; אין התקנה ולכן אין הסרה ואין רישום ב-Windows — מוחקים את התיקייה וזהו.
Uninstallable=no
; שום שאלה למשתמש: ה-EXE פורש ומפעיל, וזהו.
DisableWelcomePage=yes
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableFinishedPage=yes
; ‏Restart Manager סוגר אפליקציה שמחזיקה קבצים בתיקיית היעד — זה מה
; שמאפשר לעדכון העצמי להחליף את ה-exe שרץ. ההפעלה מחדש היא שלנו,
; ב-[Run], ולכן RestartApplications כבוי: אחרת התוכנה הייתה עולה פעמיים.
CloseApplications=yes
RestartApplications=no
; הסקריפט יושב תחת installer\, אז מגדירים את שורש הריפו כמקור כדי
; שנתיבי ה-Source יהיו יחסיים אליו ולא ל-installer\ עצמה.
SourceDir=..
OutputDir=installer\output
OutputBaseFilename=otzaria-subset-{#MyAppVersion}
; דחיסה מקסימלית: ה-EXE הזה יורד מחדש בכל עדכון עצמי, וגודלו הוא מה
; שהמשתמש משלם עליו בפס רוחב.
Compression=lzma2/ultra64
InternalCompressLevel=ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
; ‏Hebrew.isl מגיע בתקנה הרגילה של Inno Setup 6 תחת Languages\ (יחד עם
; שאר קובצי התרגום הרשמיים) — לא צריך הורדה נפרדת.
Name: "hebrew"; MessagesFile: "compiler:Languages\Hebrew.isl"

[Files]
; ‏flutter build windows --release מייצר את ה-exe, ה-DLL-ים ותיקיית
; data תחת הנתיב הזה. ה-Excludes מוריד סמלי ניפוי שאין להם שימוש אצל
; המשתמש ורק מנפחים את ההורדה.
Source: "app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Excludes: "*.pdb,*.exp,*.lib"; Flags: recursesubdirs createallsubdirs ignoreversion

[Run]
; מופעל תמיד, גם בהרצה שקטה — כי ההרצה השקטה היא העדכון העצמי, ואחריו
; המשתמש מצפה שהתוכנה תחזור.
Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Flags: nowait

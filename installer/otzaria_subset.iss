; סקריפט Inno Setup לאפליקציית "ספרייה חלקית לאוצריא".
; MyAppVersion מגיע תמיד מ-/DMyAppVersion בשורת הפקודה (ה-workflow מזרים
; אותו מה-pubspec אחרי ה-bump) — במתכוון אין #define ברירת מחדל כאן,
; כדי שקומפילציה בלי /D תיכשל בקול רם במקום לייצר גרסה שקרית.
#define MyAppName "ספרייה חלקית לאוצריא"
#define MyAppPublisher "Otzaria"
#define MyAppExeName "otzaria_subset_app.exe"

[Setup]
; GUID קבוע לאפליקציה הזו — לא לשנות בין גרסאות, הוא מה שמזהה שדרוג מול התקנה קיימת.
AppId={{7B7C7B9A-3D9B-4E9C-9E9B-6E0D6D9B7C21}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
; הסקריפט יושב תחת installer\, אז מגדירים את שורש הריפו כמקור כדי
; שנתיבי ה-Source יהיו יחסיים אליו ולא ל-installer\ עצמה.
SourceDir=..
OutputDir=installer\output
OutputBaseFilename=otzaria-subset-setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
; ‏Hebrew.isl מגיע בתקנה הרגילה של Inno Setup 6 תחת Languages\ (יחד עם
; שאר קובצי התרגום הרשמיים) — לא צריך הורדה נפרדת.
Name: "hebrew"; MessagesFile: "compiler:Languages\Hebrew.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; ‏flutter build windows --release מייצר את ה-exe, ה-DLL-ים ותיקיית
; data תחת הנתיב הזה — הכל מועתק רקורסיבית כמו שהוא.
Source: "app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

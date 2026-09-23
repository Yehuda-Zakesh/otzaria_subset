# בונה את קובץ ההפצה: EXE אחד שפורש תיקייה אחת לצדו ומפעיל אותה.
#
# שלושה שלבים — בניית ה-stub, אריזת פלט Flutter ל-tar.xz, והדבקה של
# השניים עם חתימה בסוף. ההדבקה היא כל ה"קסם": ה-stub מחפש את החתימה
# ב-32 הבתים האחרונים של עצמו, ולכן אינו צריך לדעת דבר על ההיסט.
#
# הדחיסה נעשית ב-7-Zip (‏xz עם מסנן BCJ) והפריסה ב-tar.exe שבמערכת —
# שניהם קיימים גם ב-runner וגם אצל המשתמש, ולכן אין כאן שום מפרק
# משלנו ולא ספרייה חיצונית להחזיק.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Version
)

$ErrorActionPreference = 'Stop'

if ($Version.Length -gt 15) { throw "גרסה ארוכה מדי לחתימה: $Version" }

$installer = $PSScriptRoot
$root = Split-Path -Parent $installer
$release = Join-Path $root 'app\build\windows\x64\runner\Release'
if (-not (Test-Path $release)) {
  throw "לא נמצא פלט בנייה ב-$release — צריך להריץ flutter build windows --release קודם"
}

function Find-Tool([string]$name, [string[]]$candidates) {
  $found = (Get-Command $name -ErrorAction SilentlyContinue).Source
  if ($found) { return $found }
  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) { return $candidate }
  }
  throw "לא נמצא $name"
}

# ‏CMake מגיע עם Visual Studio גם כשאינו ב-PATH, וזה אותו VS שממילא
# נדרש לבניית האפליקציה.
$vs = ''
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) { $vs = & $vswhere -latest -products * -property installationPath }
$cmake = Find-Tool 'cmake' @("$vs\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe")
$sevenZip = Find-Tool '7z' @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")

$build = Join-Path $installer 'build'
& $cmake -S (Join-Path $installer 'stub') -B $build -A x64
if ($LASTEXITCODE -ne 0) { throw "הגדרת CMake נכשלה ($LASTEXITCODE)" }
& $cmake --build $build --config Release
if ($LASTEXITCODE -ne 0) { throw "בניית ה-stub נכשלה ($LASTEXITCODE)" }

# ‏tar ואז xz בנפרד, ולא -txz ישירות על התיקייה: 7-Zip לא יוצר tar
# ודוחס אותו בפעולה אחת, ו-tar הוא מה שהצד השני יודע לפרוס.
$tar = Join-Path $build 'payload.tar'
$archive = Join-Path $build 'payload.tar.xz'
Remove-Item $tar, $archive -ErrorAction SilentlyContinue
& $sevenZip a -ttar -bso0 -bsp0 $tar "$release\*"
if ($LASTEXITCODE -ne 0) { throw "אריזת ה-tar נכשלה ($LASTEXITCODE)" }
# ‏-mf=BCJ: רוב המטען הוא קוד x86-64 (‏flutter_windows.dll לבדו 21MB),
# והמסנן מוריד ממנו עוד כמה מאות קילובייטים לפני הדחיסה.
& $sevenZip a -txz -mx=9 -mf=BCJ -bso0 -bsp0 $archive $tar
if ($LASTEXITCODE -ne 0) { throw "דחיסת ה-xz נכשלה ($LASTEXITCODE)" }

$outDir = Join-Path $installer 'output'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
# שם קבוע, בלי גרסה: ה-stub דורס את OtzariaSubset.exe שליד התיקייה בכל
# עדכון עצמי, ושם עם גרסה היה משאיר ליד התיקייה EXE בשם ישן. הגרסה
# עצמה נשמרת בחתימה שבסוף הקובץ.
$out = Join-Path $outDir 'OtzariaSubset.exe'

$stub = Join-Path $build 'Release\otzaria_stub.exe'
$payloadSize = (Get-Item $archive).Length

# החתימה: magic[8] + גודל המטען (uint64) + גרסה (16 בתים, מרופדת באפסים).
$footer = [byte[]]::new(32)
[Text.Encoding]::ASCII.GetBytes('OTZSUB02').CopyTo($footer, 0)
[BitConverter]::GetBytes([uint64]$payloadSize).CopyTo($footer, 8)
[Text.Encoding]::ASCII.GetBytes($Version).CopyTo($footer, 16)

# הזרמה ולא ReadAllBytes: המטען שוקל מגהבייטים, ואין סיבה להחזיק אותו
# בזיכרון רק כדי לשרשר.
$target = [IO.File]::Create($out)
try {
  foreach ($part in @($stub, $archive)) {
    $source = [IO.File]::OpenRead($part)
    try { $source.CopyTo($target) } finally { $source.Dispose() }
  }
  $target.Write($footer, 0, $footer.Length)
} finally {
  $target.Dispose()
}

Write-Host "נבנה: $out ($([math]::Round((Get-Item $out).Length / 1MB, 2)) MB)"

# CLAUDE.md

חוזה העבודה המלא על הריפו הזה נמצא ב-[AGENTS.md](AGENTS.md) — יש לקרוא
אותו לפני כל שינוי. הוא מפרט מה כל חבילה עושה, ואת המוקשים שאסור לשבור.

שלושת הכללים שחלים על **כל** שינוי:

1. **`dart format .` ואז `flutter analyze --no-fatal-infos`** — האנליזה
   חייבת לחזור נקייה לגמרי, כולל `info`. **הריפו הוא שתי חבילות
   נפרדות**: השורש (`otzaria_subset`, המנוע) ו-`app/`
   (`otzaria_subset_app`, אפליקציית Windows) — כל אחת עם `pubspec.yaml`
   ו-`analysis_options.yaml` משלה. יש להריץ `dart format` ו-`flutter
   analyze` **בשתיהן**; `analysis_options.yaml` בשורש מוציא במפורש את
   `app/**` מהאנליזה שלו.
2. **`flutter test` חייב לעבור במלואו**, ובמיוחד
   `test/equivalence_test.dart` — הוא ההוכחה היחידה שהמסנן נכון. בדיקה
   שנופלת פירושה שהשינוי שגוי, לא שהבדיקה מחמירה מדי.
3. **הערות קצרות, בעברית, ומסבירות *למה*** — שורה או שתיים.

שתי מגבלות סביבה:

* **אסור לקרוא תוכן מ-`seforim.db` אמיתי.** המכונה מאחורי סינון תוכן
  מחמיר (נטפרי). מותר לקרוא מטא-דאטה של סכמה (`sqlite_master`,
  `PRAGMA`, `dbstat`) בלבד. הבדיקות משתמשות ב-fixtures סינתטיים.
* **יש CI, ומריצים אותו לפני שמסתמכים על בדיקה מקומית בלבד.**
  `.github/workflows/test.yml` רץ על כל push ל-`main` (וגם בדרישה
  ידנית): `pub get`, `dart format --set-exit-if-changed` ו-`flutter
  analyze` בשתי החבילות, ו-`flutter test` על השורש.
  `.github/workflows/release.yml` רץ **רק בדרישה ידנית**: מעלה patch
  version בנעילה הדדית בשני ה-`pubspec.yaml`, מריץ את הבדיקות, בונה את
  האפליקציה (עם `--dart-define=APP_VERSION`), אורז אותה ב-
  `installer/build.ps1` ל-**EXE יחיד שפורש תיקייה אחת לצדו**,
  ומפרסם תג ו-GitHub Release. אותו EXE הוא גם מה שהעדכון העצמי של
  התוכנה מוריד — ראו §16 ב-AGENTS.md.

יש להשיב למשתמש בעברית.

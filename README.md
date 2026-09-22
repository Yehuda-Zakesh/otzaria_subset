# otzaria_subset

אפליקציית Windows שמקטינה את ספריית **אוצריא** שכבר מותקנת אצל המשתמש:
היא גוזמת את `seforim.db` הקיים **במקום** לפי מה שהמשתמש מסמן **למחיקה**
(קטגוריות או ספרים בודדים), וממשיכה לעדכן אותו — על ידי סינון קובצי
ה-patch של אוצריא לאותה תת-קבוצה לפני ההחלה, ובנייה מחדש ממסד מלא
כשהבחירה מתרחבת או שהסכמה משתנה.

**המשתמש מסמן מה למחוק, לא מה להשאיר.** מסך הבחירה (`BookSelectionScreen`
+ `CategoryTree`) עובד על `RemovalSelection` — קטגוריות וספרים שסומנו
למחיקה. המנוע עצמו לא השתנה: הוא עדיין מקבל `SubsetSpec`, כלל של מה
*נשאר*, וזה מה שמבחן השקילות מוכיח. התרגום בין שתי השפות הוא
`keepSpecFor` ב-[`lib/src/engine/removal_plan.dart`](lib/src/engine/removal_plan.dart).
הנקודה החשובה: ענף שלם שהמשתמש לא נגע בו נשמר ככלל **קטגוריה אחת**, לא
כרשימת מזהי ספרים — כך ספר שאוצריא תוסיף מחר לקטגוריה שנשמרה ייכנס
מעצמו, וספר שתוסיף לקטגוריה שנמחקה לא ייכנס. רק ענף **מעורב** (חלקו
נמחק) מפורק לספרים בודדים. ראו `test/removal_plan_test.dart`.

## שתי חבילות

| חבילה | תיקייה | תפקיד |
|---|---|---|
| `otzaria_subset` | `lib/` | **המנוע** — לוגיקה טהורה, בלי widgets: גיזום, סינון patch, hash לוגי, פרופילים. `pubspec.yaml` ו-`analysis_options.yaml` משלה. |
| `otzaria_subset_app` | `app/` | **האפליקציה** — Flutter ל-Windows. מסכים, זרימת עדכון, איתור התקנת אוצריא, הרצה ב-`Isolate`. תלויה ב-`otzaria_subset` דרך path dependency. |

שתי החבילות חייבות לעבור `dart format` ו-`flutter analyze
--no-fatal-infos` נקי — כל אחת מהתיקייה שלה. `analysis_options.yaml`
בשורש מוציא במפורש את `app/**`, כי היא חבילה נפרדת.

## שלוש דרישות שהעיצוב בנוי סביבן

**אין הורדה של מסד נפרד להתקנה.** המשתמש כבר הוריד את `seforim.db`
המלא דרך אוצריא עצמה. הגיזום הראשוני בונה תת-קבוצה חדשה **לצד** הקובץ
הקיים (staging), מאמת אותה, ורק אז מחליף אטומית — מקור ויעד הם אותו
נתיב. הורדת מסד מלא נפרדת קורית רק במסלול הנדיר של שינוי סכמה (ראו
למטה).

**שלושה מצבים, לא שניים:** גיזום ראשוני, עדכוני patch מסוננים שוטפים,
ובנייה מחדש כשהבחירה מתרחבת (ספר חדש בקטגוריה שנבחרה, שאינו מגיע
מ-patch) או כשהסכמה משתנה.

**אין עדכון-עצמי ואין מערכת תוספים, במכוון.** האפליקציה מעדכנת רק את
ספריית אוצריא, לא את עצמה, ואינה טוענת קוד חיצוני.

---

## למה זה בכלל אפשרי

שלוש עובדות שנמדדו על המסד האמיתי (סכמה 5, 7.42GB) ועל קובץ patch אמיתי
(`patch-v16-v17.db`). הן מה שמפריד בין הפרויקט הזה לבין רעיון לא-ישים:

### 1. כל טבלה שקשורה לספר נושאת `bookId` במפורש, `NOT NULL`

```
line.bookId               NOT NULL
tocEntry.bookId           NOT NULL
book_version.bookId       NOT NULL
alt_toc_structure.bookId  NOT NULL
link.sourceBookId + link.targetBookId   ← שני הצדדים על השורה עצמה
line_ref / line_dh        bookId בתוך ה-PK
כל טבלאות book_*          bookId בתוך ה-PK
```

`link` היא המתנה הגדולה: שני צדי הקישור מנורמלים על השורה, ולכן סינון
קישורים הוא `WHERE sourceBookId IN K AND targetBookId IN K` — לא JOIN.

### 2. ה-patch נושא את **מלוא** העמודות, לא תת-קבוצה

```
upsert_line  | id, bookId, lineIndex, content, heRef, tocEntryId, charCount
upsert_link  | id, sourceBookId, targetBookId, sourceLineId, targetLineId, …
upsert_book  | כל 22 העמודות
```

כלומר אפשר לייחס כל שורת patch לספר **מקובץ ה-patch בלבד**, בלי JOIN
למסד המקומי ובלי ניחוש.

### 3. ~99.7% מהמסד גזים; הליבה הגלובלית היא ~20MB

| טבלה | MB | גזים? |
|---|---:|:---:|
| `line` | 4,759 | ✅ |
| `version_line` | 818 | ✅ |
| `idx_line_heref` | 277 | ✅ |
| `link` + ~9 אינדקסים | ~700 | ✅ |
| `line_dh` / `line_ref` / `line_toc` | 272 | ✅ |
| **גלובלי** (`tocText`, `book`, `author`, `topic`, `category`, …) | **~20** | ❌ |

הטבלאות הגלובליות נשמרות **במלואן**, וזה מה שמשאיר את שמונה אילוצי
ה-`UNIQUE` הגלובליים מתנהגים בדיוק כמו באפסטרים — כולל `tocText.text`
ו-`author.name`, שהם בדיוק המקום שבו אפסטרים נכווה (issue #19 שם).

---

## ארכיטקטורה — המנוע (`lib/`)

הלב הוא [`lib/src/models/table_scope.dart`](lib/src/models/table_scope.dart) —
סיווג של כל 37 הטבלאות. **כל השאר נגזר ממנו.**

```
K = קבוצת מזהי הספרים הנבחרת

global   (11 טבלאות)  → נשמר שלם, patch מוחל שלם
byBook                → כל עמודות ה-bookId ∈ K
                        book, line, tocEntry, book_version,
                        alt_toc_structure, line_ref, line_dh,
                        book_has_links, book_*
                        link (sourceBookId ∧ targetBookId)
                        default_commentator / default_targum (שני הצדדים)
byParent              → שורת ההורה שרדה — בדיקה מקומית, בלי שיוך לספר
                        line_toc, link_anchor, link_range, link_coverage,
                        link_suppressed_side, version_line,
                        alt_toc_entry, line_alt_toc
```

| רכיב | תפקיד |
|---|---|
| `SubsetResolver` | כלל → מזהי ספרים, אומדן גודל, דוח קישורים מנותקים, וספרים חדשים בקטגוריה |
| `SubsetBuilder` | מסד מלא → תת-קבוצה |
| `PatchFilter` | `patch.db` → `patch.db` מסונן |
| `SubsetUpdater` | מתזמר: אימות → סינון → החלה על העתק → אימות → החלפה |
| `SubsetRebuilder` | בנייה מחדש (או גיזום במקום) ממסד מלא, כולל ביטול אינדקס החיפוש |
| `SubsetHasher` | hash לוגי חלקי, בקידומת `subset:` |
| `LibraryCatalog` / `readCatalogFromPath` | עץ הקטגוריות והספרים למסך הבחירה |
| `RemovalSelection` / `keepSpecFor` (`removal_plan.dart`) | מתרגם סימון-למחיקה של המשתמש (מה שהעץ מציג) לכלל-שמירה (`SubsetSpec`) שהמנוע עובד איתו |
| `ProfileStore` | פרופיל לכל מחשב יעד, JSON אטומי על הכונן |
| `MachineIdentity` | זיהוי עצמי של המחשב — המשתמש אינו בוחר פרופיל מרשימה |
| `OtzariaUpdateGuard` | לוגיקת הכרעה טהורה (לא קורא בעצמו כלום): מקבל ערכים גולמיים וקובע אם עדכון הספרייה של אוצריא כבוי |

### שני דברים שנעשים אחרת ממה שנראה מתבקש

**`delete_*` מועתקות במלואן, בלי סינון.** `DELETE WHERE pk IN (...)` על
שורה שאינה קיימת הוא no-op. סינון שלהן היה עבודה מיותרת עם סיכוי לטעות.

**ההחלה רצה על העתק.** `PatchApplier` של אפסטרים מאמת בתוך ה-transaction
מול `toContentHash` ומגלגל אחורה. על מסד חלקי ה-hash הזה לא יתאים לעולם,
ולכן האימות כבוי — ואיתו נעלם ה-`ROLLBACK`. `SubsetUpdater` מחזיר את
הבטיחות שכבה אחת מעל: staging → אימות → `rename` אטומי.

---

## האפליקציה (`app/`)

`app/lib/main.dart` הוא נקודת הכניסה: `RTL` נכפה גלובלית (אין תרגומים,
רק כיוון), ו-`AppState` (ב-`app/lib/state/app_state.dart`) מוחזק דרך
`InheritedNotifier` יחיד (`AppScope`).

| רכיב | תפקיד |
|---|---|
| `HomeShell` + `HomeScreen` | מסך הבית: כמה ספרים, כמה מקום, מצב עדכון. שום מנגנון פנימי (גרסאות, hash, נתיבים) לא מגיע לכאן. |
| `BookSelectionScreen` + `CategoryTree` (`widgets/category_tree.dart`) | עץ הבחירה — **סימון פירושו מחיקה** — עם debounce ואומדן חי דרך `SubsetResolver`, ותרגום ל-`SubsetSpec` דרך `keepSpecFor` |
| `AppTheme` / `AppColors` (`theme.dart`) | הזהות החזותית של האפליקציה — ראו "זהות חזותית" למטה |
| `ProgressScreen` | מתרגם את שלבי המנוע לארבע תחנות: מוריד/מכין/מחיל/מסיים |
| `SettingsScreen` | נתיב הספרייה (דריסה ידנית), מקור העדכונים |
| `SubsetUpdateFlow` (`services/update_flow.dart`) | מחברת גילוי → תכנון → הורדה → סינון/גיזום לזרימה אחת |
| `OtzariaInstallLocator` (`services/otzaria_install.dart`) | מאתר את התקנת אוצריא דרך `LibraryDbLocator` של `library_manager` — לא ניחוש נתיבים; גם קורא (`readUpdateSettings`) את הגדרות העדכון שלה |
| `ZstdFileStream` (`services/zstd_stream.dart`) | פירוק zstd בהזרמה — קובץ→קובץ, וגם זרם רשת→קובץ כשמורידים מסד מלא |
| `jobs.dart` | נקודת המעבר היחידה ל-`Isolate`: כל קריאה למנוע מה-UI עוברת דרכו |

### מקור העדכונים

ברירת המחדל היא אינטרנט (`GithubLibraryReleaseClient`); למחשב מנותק יש
אפשרות לתיקייה מקומית (`LocalMirrorLibraryReleaseClient`), נבחרת
במסך ההגדרות. אין מסלול שלישי.

### איתור אוצריא וחסימות

ה-`seforim.db` מאותר דרך `LibraryDbLocator` של `library_manager`, שקורא
את קופסת ה-Hive של אוצריא עצמה — לא תיקיות ברירת מחדל מנוחשות.
`OtzariaProcessGuard` חוסם כל גיזום כל עוד אוצריא רצה, כדי לא להחליף
קובץ שהיא מחזיקה פתוח.

### עדכון הספרייה של אוצריא עצמה

ההגדרות של אוצריא יושבות בקופסת **Hive** (`app_preferences.hive`) בשורש
הנתונים שלה, לא בקובץ JSON. `OtzariaUpdateGuard`
(`lib/src/store/otzaria_update_guard.dart`) הוא לוגיקת הכרעה טהורה —
`fromValues` / `unknown` — בלי גישה לדיסק כלל, כי לקופסת Hive אין מקום
בחבילת לוגיקה. הקריאה בפועל היא ב-`readUpdateSettings`
(`app/lib/services/otzaria_install.dart`): מעתיקה את `app_preferences.hive`
מהתיקייה של אוצריא לתיקייה זמנית, פותחת אותה עם `hive_ce`, וקוראת את
המפתחות `key-software-and-book-updates-enabled`, `key-auto-sync` ו-
`key-offline-mode` (כולם דלוקים כברירת מחדל — כלומר מסוכנים; ואי-ידיעה
**לא** נחשבת כבוי). קריאה דרך עותק, לא במקום, כי פתיחת הקופסה במקומה
יוצרת קובץ נעילה שמתנגש עם אוצריא כשהיא פתוחה. האפליקציה **אינה כותבת**
להגדרות של אוצריא: כתיבה מבחוץ שברירית ועלולה להימחק בשקט בפתיחה הבאה
שלה. במקום זה היא מזהה, חוסמת המשך, ומנחה את המשתמש איך לכבות בעצמו —
ראו `UpdateGuardBanner` ו-`showUpdateGuardDialog` ב-
`app/lib/widgets/update_guard.dart`.

### זהות חזותית

`app/lib/theme.dart` מגדיר פלטה במכוון רחוקה מזו של אוצריא: סגול-אינדיגו
(`AppColors.seed`) עם מבטא טורקיז (`AppColors.accent`), גרדיאנט בכרטיס
הפתיחה ובסרגל הצד, וכרטיסים שטוחים ומעוגלים. הסיבה היא בטיחות, לא טעם:
התוכנה הזו מוחקת ספרים, ומשתמש שיחשוב שזו אוצריא יאשים את אוצריא במה
שקרה. בנוסף, טקסט למשתמש אינו מכיל מונחים פנימיים (hash, patch, staging,
גרסת סכמה, "subset"/"מסד חלקי") — המשתמש רואה ספרים, גודל ומצב, לא איך
זה עובד מבפנים.

---

## מבחן השקילות

זו הבדיקה שקובעת אם הפרויקט עובד.
[`test/equivalence_test.dart`](test/equivalence_test.dart) מוכיח:

```
subset_K(apply(patch, full))  ==  apply(filter_K(patch), subset_K(full))
```

צד שמאל הוא האמת: מחילים על המלא, ואז גוזמים. צד ימין הוא מה שהתוכנה
עושה: גוזמים פעם אחת, ומאז מחילים patches מסוננים. ההשוואה היא על ה-hash
הלוגי — כל תא בכל טבלה בסדר קנוני, לא ספירות שורות.

**כל שינוי במסנן או בסיווג הטבלאות חייב להשאיר את הבדיקה הזו ירוקה.**

---

## שלוש מגבלות אמיתיות

### 1. ספר שנכנס לבחירה מאוחר אינו מגיע מ-patch

`patch` נושא רק את מה שהשתנה. ספר שקיים באוצריא כבר כמה גרסאות ורק עכשיו
עובר לקטגוריה שהמשתמש בחר מגיע עם שורת `book` בלבד — הטקסט שלו לא השתנה
ולכן אינו שם. **אין דרך להשיג אותו מקובץ עדכון.**

זה מטופל במפורש: `PatchKeepResolution.pendingAcquisition` מחזיק ספרים
כאלה, והם **אינם** נכנסים לספרייה חצי-ריקים. הם ממתינים להבאה ממסד מלא,
והמשתמש רואה זאת במסך הבית — ראו `_PendingCard` ב-`home_screen.dart`.

### 2. `migrations` לא ריקה → סירוב

מיגרציה היא SQL שרירותי שנכתב בהנחה שהמסד שלם; אחת שממלאת נתונים תיתן על
תת-קבוצה תוצאה אחרת **בשקט**. לכן `PatchFilter` זורק, והמסלול הוא בנייה
מחדש ממסד מלא.

### 3. אין אימות מול אפסטרים

ה-hash של אוצריא הוא על המסד המלא. מסד חלקי לא יתאים לו לעולם.
`SubsetHasher` מחשב hash **משלנו**, בקידומת `subset:` כדי שלא יתחלף.

מה שהוא כן נותן: זיהוי סחף ושחיתות בשרשרת שלנו בין עדכונים.
מה שהוא **לא** נותן: הוכחה שהמסנן צודק — לזה יש רק מבחן השקילות.

---

## כשהסכמה משתנה

שינוי סכמה שובר את קובצי ה-patch (כך גם באוצריא עצמה). זה המסלול היחיד
שבו האפליקציה מורידה מסד נפרד:

1. הורדת המסד המלא (~1.5GB דחוס) — הזרם עובר מהרשת ישר למחלץ
   (`ZstdFileStream`), הארכיון אינו יורד לדיסק
2. בנייה מחדש לפי הבחירה של הפרופיל, אל נתיב הספרייה של המשתמש
3. מחיקת המסד המלא הזמני שהורד

**שיא התפוסה: ~7.4GB + התת-קבוצה.** ‏SQLite דורש גישה מקרית כדי לשאול,
ולכן המסד המלא חייב להתממש פעם אחת — אין דרך לשאול זרם שמתפרק. לפני
ההורדה נבדק מקום פנוי (`DiskSpaceProbe`). זה המסלול הנדיר: שינוי סכמה
קרה ~5 פעמים בהיסטוריה של הספרייה. המסלול השוטף — patches מסוננים —
אינו מממש מסד מלא כלל, וגם הגיזום הראשוני גוזם את הקובץ הקיים במקום.

---

## הרצה ובנייה

```bash
# המנוע (שורש)
flutter pub get
flutter test                              # כל הבדיקות
flutter test test/equivalence_test.dart   # מבחן השקילות בלבד
dart format .
flutter analyze --no-fatal-infos

# האפליקציה
cd app
flutter pub get
dart format .
flutter analyze --no-fatal-infos
flutter run -d windows                    # הרצה
flutter build windows --release           # בנייה
```

הבדיקות בונות מסדים סינתטיים זעירים בתיקייה זמנית. **אף בדיקה אינה נוגעת
במסד אמיתי של אוצריא ואינה מכילה תוכן ספרים.**

`.github/workflows/test.yml` מריץ את כל השלבים האלה אוטומטית על כל push
ל-`main`. `.github/workflows/release.yml`, שרץ רק בדרישה ידנית, מוסיף
בנייה, אריזה ב-Inno Setup (`installer/otzaria_subset.iss`), ופרסום
GitHub Release.

### פעולות חוסמות

`SubsetBuilder.build`, `PatchFilter.filter`, `SubsetHasher.compute`,
`SubsetUpdater.applyPatch` ו-`SubsetRebuilder.rebuild` סינכרוניות
וכבדות (בנייה ממסד מלא נמשכת דקות). באפליקציה כל קריאה כזו עוברת דרך
`app/lib/jobs/jobs.dart`, שמריץ אותה ב-`Isolate` עם closure שקורא
לפונקציה **גלובלית** שמקבלת פרימיטיבים בלבד — closure שנוגע בשדה מופע
לוכד גם אותו וזורק `object is unsendable`.

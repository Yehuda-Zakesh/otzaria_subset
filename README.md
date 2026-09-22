# otzaria_subset

מנוע **ספרייה חלקית** לאוצריא: מאפשר למשתמש להחזיק רק חלק מ-`seforim.db`
(לפי קטגוריות או ספרים בודדים) **ולהמשיך לקבל עדכונים** — על ידי סינון
קובצי ה-patch של אוצריא לאותה תת-קבוצה לפני ההחלה.

> **זו חבילת לוגיקה, לא אפליקציה.** אין כאן widgets. הגילוי, התכנון,
> ההורדה וההחלה נשארים ב-[`seforim_library_updater`](../Otzariya_update);
> כאן נוספים שני דברים בלבד — **גיזום** ו**סינון patch**.

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

## ארכיטקטורה

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
| `SubsetHasher` | hash לוגי חלקי, בקידומת `subset:` |
| `ProfileStore` | פרופיל לכל מחשב יעד, JSON אטומי על הכונן |
| `MachineIdentity` | זיהוי עצמי של המחשב — המשתמש אינו בוחר פרופיל מרשימה |

### שני דברים שנעשים אחרת ממה שנראה מתבקש

**`delete_*` מועתקות במלואן, בלי סינון.** `DELETE WHERE pk IN (...)` על
שורה שאינה קיימת הוא no-op. סינון שלהן היה עבודה מיותרת עם סיכוי לטעות.

**ההחלה רצה על העתק.** `PatchApplier` של אפסטרים מאמת בתוך ה-transaction
מול `toContentHash` ומגלגל אחורה. על מסד חלקי ה-hash הזה לא יתאים לעולם,
ולכן האימות כבוי — ואיתו נעלם ה-`ROLLBACK`. `SubsetUpdater` מחזיר את
הבטיחות שכבה אחת מעל: staging → אימות → `rename` אטומי.

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
כאלה, והם **אינם** נכנסים לספרייה חצי-ריקים. הם ממתינים להבאה ממסד מלא.

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

שינוי סכמה שובר את קובצי ה-patch (כך גם באוצריא עצמה). המסלול:

1. הורדת המסד המלא (~1.5GB דחוס) — הזרם עובר מהרשת ישר למחלץ, הארכיון
   אינו יורד לדיסק
2. גיזום מיידי לפי הבחירה של הפרופיל
3. מחיקת המסד המלא

**שיא התפוסה: ~7.4GB + התת-קבוצה.** ‏SQLite דורש גישה מקרית כדי לשאול,
ולכן המסד המלא חייב להתממש פעם אחת — אין דרך לשאול זרם שמתפרק. זה
המסלול הנדיר: שינוי סכמה קרה ~5 פעמים בהיסטוריה של הספרייה. המסלול
השוטף — patches מסוננים — אינו מממש מסד מלא כלל.

---

## הרצה

```bash
flutter pub get
flutter test                      # כל הבדיקות
flutter test test/equivalence_test.dart   # מבחן השקילות בלבד
flutter analyze --no-fatal-infos
```

הבדיקות בונות מסדים סינתטיים זעירים בתיקייה זמנית. **אף בדיקה אינה נוגעת
במסד אמיתי של אוצריא ואינה מכילה תוכן ספרים.**

### פעולות חוסמות

`SubsetBuilder.build`, `PatchFilter.filter`, `SubsetHasher.compute`
ו-`SubsetUpdater.applyPatch` **סינכרוניות וכבדות** (בנייה ממסד מלא נמשכת
דקות). אל תריץ אותן על ה-UI isolate — עטוף ב-`Isolate.run`, עם closure
שקורא לפונקציה **גלובלית** שמקבלת פרימיטיבים בלבד.

import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../models/subset_spec.dart';
import 'keep_set.dart';

/// פותר [SubsetSpec] מול מסד נתונים: מזהי הספרים בפועל, אומדן הגודל, ודוח
/// הקישורים שיינתקו.
///
/// כל השאילתות כאן **קריאה בלבד** ואינן נוגעות בטבלאות התוכן הענקיות
/// (`line`, `version_line`) — הן רצות על `book`, `category_closure`
/// ו-`link`, שמסתדרות באינדקסים. פתירה על המסד המלא לוקחת שניות, לא
/// דקות, כדי שה-UI יוכל להציג את המחיר בזמן שהמשתמש מסמן קטגוריות.
class SubsetResolver {
  /// מקדם הביטחון על אומדן הגודל. אומדן שנופל מתחת לגודל האמיתי גורם
  /// לכשל באמצע בנייה אחרי שהמשתמש חיכה, ולכן האומדן מכוון לצד הגבוה.
  static const double sizeSafetyFactor = 1.15;

  const SubsetResolver();

  /// מזהי הספרים שהכלל [spec] בוחר, בלי לגעת בקישורים.
  ///
  /// הסדר: קטגוריות (כולל כל צאצאיהן דרך `category_closure`) ⊎ ספרים
  /// מפורשים, ואז חיסור [SubsetSpec.excludeBookIds] — ההחרגה תמיד אחרונה.
  Set<int> resolveBookIds(sqlite3.Database db, SubsetSpec spec) {
    final ids = <int>{};

    if (spec.categoryIds.isNotEmpty) {
      // ‏category_closure הוא טבלת סגור: שורה לכל (אב, צאצא), כולל
      // ‏(x, x). די בשאילתה אחת ללא רקורסיה.
      final placeholders = List.filled(spec.categoryIds.length, '?').join(',');
      final rows = db.select(
        'SELECT b.id FROM book b '
        'WHERE b.categoryId IN ('
        '  SELECT descendantId FROM category_closure '
        '  WHERE ancestorId IN ($placeholders)'
        ')',
        spec.categoryIds.toList(),
      );
      for (final row in rows) {
        ids.add(row['id'] as int);
      }
    }

    ids.addAll(spec.includeBookIds);
    ids.removeAll(spec.excludeBookIds);
    return ids;
  }

  /// הקטגוריות שנשמרות בתת-הקבוצה.
  ///
  /// הכלל, ושני חלקיו נחוצים:
  ///
  /// * **אבות של קטגוריות הספרים שנבחרו** — בלעדיהם אין נתיב מהשורש אל
  ///   הספר, ועץ הספרייה באוצריא נשבר.
  /// * **צאצאי הקטגוריות שנבחרו, ואבותיהן** — זה מה שמשאיר את היכולת
  ///   לקבל ספר חדש. `resolveForPatch` מזהה ספר חדש לפי `categoryId`
  ///   שלו מול הסגור המקומי; אם הקטגוריה נגזמה, הספר לא ייפתר לעולם.
  ///
  /// שתי הטבלאות נקראות במלואן ומסוננות ב-Dart. זה מכוון: `book` היא
  /// ~2.4MB ו-`category_closure` קטנה ממנה, וסריקה שלהן זולה מכל תרגיל
  /// של טבלאות עזר — ומשאירה את הפונקציה בדיקה טהורה.
  Set<int> resolveCategoryIds(
    sqlite3.Database db, {
    required Set<int> selectedCategoryIds,
    required Set<int> bookIds,
  }) {
    // הסגור: אב → צאצאים, וצאצא → אבות.
    final descendantsOf = <int, Set<int>>{};
    final ancestorsOf = <int, Set<int>>{};
    for (final row
        in db.select('SELECT ancestorId, descendantId FROM category_closure')) {
      final a = row['ancestorId'] as int;
      final d = row['descendantId'] as int;
      (descendantsOf[a] ??= <int>{}).add(d);
      (ancestorsOf[d] ??= <int>{}).add(a);
    }

    final keep = <int>{};

    // אבות של הקטגוריות שבהן יושבים הספרים שנבחרו.
    for (final row in db.select('SELECT id, categoryId FROM book')) {
      if (!bookIds.contains(row['id'] as int)) continue;
      final cat = row['categoryId'] as int;
      keep.add(cat);
      keep.addAll(ancestorsOf[cat] ?? const <int>{});
    }

    // הקטגוריות שנבחרו, צאצאיהן ואבותיהן.
    for (final selected in selectedCategoryIds) {
      keep.add(selected);
      keep.addAll(descendantsOf[selected] ?? const <int>{});
      keep.addAll(ancestorsOf[selected] ?? const <int>{});
    }

    return keep;
  }

  /// מזהי הספרים שהכלל בוחר **אחרי** שה-patch יוחל — לא לפני.
  ///
  /// זו הנקודה שבה "עדכון מותאם למה שהמשתמש הוריד" נשבר או עובד. משתמש
  /// שבחר קטגוריה צריך לקבל מסכת/ספר שנוספו לה בגרסה החדשה; פתירה מול
  /// המסד המקומי בלבד לא הייתה רואה אותם כלל, והם לא היו מגיעים לעולם.
  ///
  /// אפשר לפתור את זה בלי המסד המלא מפני ש-`category` ו-`category_closure`
  /// נשמרות **במלואן** בכל תת-קבוצה: עץ הקטגוריות המקומי שלם, ולכן די
  /// ב-`upsert_book.categoryId` שבקובץ ה-patch כדי לדעת לאן ספר חדש שייך.
  ///
  /// [subsetDb] הוא חיבור למסד החלקי של המשתמש; [patchPath] קובץ ה-patch
  /// הגולמי (לפני סינון — הסינון תלוי בתוצאה הזו).
  /// מחזירה גם את הספרים שהכלל בוחר אך תוכנם אינו זמין — ראו
  /// [PatchKeepResolution] להסבר למה ההפרדה הזו חייבת להיות מפורשת.
  PatchKeepResolution resolveForPatch(
    sqlite3.Database subsetDb,
    SubsetSpec spec,
    String patchPath,
  ) {
    subsetDb.execute('ATTACH DATABASE ? AS praw', [patchPath]);
    try {
      final ids = <int>{};
      if (spec.categoryIds.isNotEmpty) {
        final placeholders =
            List.filled(spec.categoryIds.length, '?').join(',');
        final args = spec.categoryIds.toList();

        // הסגור האפקטיבי: המקומי, בתוספת מה שה-patch מוסיף ובניכוי מה
        // שהוא מוחק. שלושת החלקים נדרשים — patch שמעביר ספר בין קטגוריות
        // נוגע בכולם.
        final closure = _union(
          subsetDb,
          base: 'SELECT ancestorId, descendantId FROM main.category_closure',
          added: _has(subsetDb, 'praw', 'upsert_category_closure')
              ? 'SELECT ancestorId, descendantId '
                  'FROM praw.upsert_category_closure'
              : null,
          removedTable: _has(subsetDb, 'praw', 'delete_category_closure')
              ? 'praw.delete_category_closure'
              : null,
          keyColumns: const ['ancestorId', 'descendantId'],
        );

        // ספר אפקטיבי: הגרסה שב-patch גוברת על המקומית (אותו `id`).
        final books = _has(subsetDb, 'praw', 'upsert_book')
            ? 'SELECT id, categoryId FROM praw.upsert_book '
                'UNION ALL '
                'SELECT id, categoryId FROM main.book '
                'WHERE id NOT IN (SELECT id FROM praw.upsert_book)'
            : 'SELECT id, categoryId FROM main.book';

        final rows = subsetDb.select(
          'WITH eff_closure AS ($closure), eff_book AS ($books) '
          'SELECT b.id FROM eff_book b '
          'WHERE b.categoryId IN ('
          '  SELECT descendantId FROM eff_closure '
          '  WHERE ancestorId IN ($placeholders)'
          ')',
          args,
        );
        for (final row in rows) {
          ids.add(row['id'] as int);
        }
      }

      ids.addAll(spec.includeBookIds);
      ids.removeAll(spec.excludeBookIds);

      // ספר שה-patch מוחק יורד מהבחירה גם אם הכלל עוד בוחר אותו — אחרת
      // הוא היה נשאר ברשימה ומייצר ציפייה לשורות שלא יגיעו.
      if (_has(subsetDb, 'praw', 'delete_book')) {
        for (final row in subsetDb.select('SELECT id FROM praw.delete_book')) {
          ids.remove(row['id'] as int);
        }
      }

      final split = _splitByAvailability(subsetDb, ids);
      return PatchKeepResolution(
        keep: split.keep,
        pendingAcquisition: split.pendingAcquisition,
        keepCategories: _effectiveCategories(subsetDb, spec, split.keep),
      );
    } finally {
      try {
        subsetDb.execute('DETACH DATABASE praw');
      } catch (_) {}
    }
  }

  /// הקטגוריות שנשמרות, מחושבות מול המצב **שאחרי** ה-patch.
  ///
  /// חייב להיות הסגור האפקטיבי ולא המקומי: patch שמוסיף תת-קטגוריה
  /// לקטגוריה שנבחרה חייב להכניס גם אותה, אחרת ספר שיגיע לשם בעדכון הבא
  /// לא ייפתר. ה-`praw` מחובר כבר על ידי [resolveForPatch].
  Set<int> _effectiveCategories(
    sqlite3.Database db,
    SubsetSpec spec,
    Set<int> bookIds,
  ) {
    final descendantsOf = <int, Set<int>>{};
    final ancestorsOf = <int, Set<int>>{};

    final closureSql = _union(
      db,
      base: 'SELECT ancestorId, descendantId FROM main.category_closure',
      added: _has(db, 'praw', 'upsert_category_closure')
          ? 'SELECT ancestorId, descendantId FROM praw.upsert_category_closure'
          : null,
      removedTable: _has(db, 'praw', 'delete_category_closure')
          ? 'praw.delete_category_closure'
          : null,
      keyColumns: const ['ancestorId', 'descendantId'],
    );
    for (final row in db.select(closureSql)) {
      final a = row['ancestorId'] as int;
      final d = row['descendantId'] as int;
      (descendantsOf[a] ??= <int>{}).add(d);
      (ancestorsOf[d] ??= <int>{}).add(a);
    }

    final booksSql = _has(db, 'praw', 'upsert_book')
        ? 'SELECT id, categoryId FROM praw.upsert_book '
            'UNION ALL '
            'SELECT id, categoryId FROM main.book '
            'WHERE id NOT IN (SELECT id FROM praw.upsert_book)'
        : 'SELECT id, categoryId FROM main.book';

    final keep = <int>{};
    for (final row in db.select(booksSql)) {
      if (!bookIds.contains(row['id'] as int)) continue;
      final cat = row['categoryId'] as int;
      keep.add(cat);
      keep.addAll(ancestorsOf[cat] ?? const <int>{});
    }
    for (final selected in spec.categoryIds) {
      keep.add(selected);
      keep.addAll(descendantsOf[selected] ?? const <int>{});
      keep.addAll(ancestorsOf[selected] ?? const <int>{});
    }
    return keep;
  }

  /// מפצל את הבחירה לספרים שאפשר לתחזק דרך ה-patch הזה, ולספרים שהתוכן
  /// שלהם חסר.
  ///
  /// ספר נכנס ל-`keep` באחד משלושה תנאים:
  ///
  /// * הוא **כבר קיים מקומית** — יש לו תוכן, וה-patch רק מעדכן אותו.
  /// * ה-patch **מביא לו שורות** (`upsert_line`) — ספר חדש לגמרי, שכל
  ///   תוכנו נמצא בקובץ העדכון.
  /// * `totalLines == 0` — ספר ריק לגיטימי, אין מה להביא.
  ///
  /// כל השאר הוא ספר שהיה קיים באוצריא מזמן ורק עכשיו נכנס לבחירה. אין
  /// דרך להשיג את תוכנו מ-patch, ולכן הוא ממתין להבאה ממסד מלא ולא נכנס
  /// לתת-הקבוצה חצי-ריק.
  PatchKeepResolution _splitByAvailability(
      sqlite3.Database db, Set<int> candidates) {
    if (candidates.isEmpty) {
      return const PatchKeepResolution(keep: {});
    }

    final local = <int>{};
    for (final row in db.select('SELECT id FROM main.book')) {
      local.add(row['id'] as int);
    }

    final suppliedByPatch = <int>{};
    if (_has(db, 'praw', 'upsert_line')) {
      for (final row
          in db.select('SELECT DISTINCT bookId FROM praw.upsert_line')) {
        final id = row['bookId'];
        if (id is int) suppliedByPatch.add(id);
      }
    }

    final emptyBooks = <int>{};
    if (_has(db, 'praw', 'upsert_book')) {
      for (final row in db
          .select('SELECT id FROM praw.upsert_book WHERE totalLines = 0')) {
        emptyBooks.add(row['id'] as int);
      }
    }

    final keep = <int>{};
    final pending = <int>{};
    for (final id in candidates) {
      if (local.contains(id) ||
          suppliedByPatch.contains(id) ||
          emptyBooks.contains(id)) {
        keep.add(id);
      } else {
        pending.add(id);
      }
    }
    return PatchKeepResolution(keep: keep, pendingAcquisition: pending);
  }

  /// בונה `SELECT` שמאחד בסיס עם תוספות ומחסיר מחיקות, לפי [keyColumns].
  String _union(
    sqlite3.Database db, {
    required String base,
    required String? added,
    required String? removedTable,
    required List<String> keyColumns,
  }) {
    final csv = keyColumns.map((c) => '"$c"').join(',');
    var sql = added == null ? base : '$base UNION $added';
    if (removedTable != null) {
      sql = 'SELECT $csv FROM ($sql) '
          'WHERE ($csv) NOT IN (SELECT $csv FROM $removedTable)';
    }
    return sql;
  }

  bool _has(sqlite3.Database db, String schema, String name) => db.select(
        "SELECT 1 FROM $schema.sqlite_master WHERE type='table' AND name=? LIMIT 1",
        [name],
      ).isNotEmpty;

  /// פותר את הכלל במלואו, כולל אומדן גודל ודוח ניתוק.
  ///
  /// [severedLinkLimit] חוסם את אורך [SubsetPlan.severedLinks]; הספירה
  /// הכוללת ב-[SubsetPlan.severedLinkCount] נשארת מדויקת. ה-UI מציג
  /// רשימה קצרה ולא 400 שורות.
  SubsetPlan resolve(
    sqlite3.Database db,
    SubsetSpec spec, {
    int severedLinkLimit = 25,
  }) {
    final bookIds = resolveBookIds(db, spec);
    KeepSet.install(db, bookIds);

    final calibration = _calibrate(db);
    return SubsetPlan(
      bookIds: bookIds,
      estimatedBytes: _estimateBytes(db, calibration),
      severedLinkCount: _countSeveredLinks(db),
      severedLinks: _severedTargets(db, calibration, severedLinkLimit),
    );
  }

  /// בייטים לשורת `line` אחת, נמדד על המסד שמול העיניים.
  ///
  /// האומדן מתבסס על `book.totalLines` ולא על סריקת `line`: סריקה של
  /// 4.7GB לכל תנועה של המשתמש ב-UI אינה אפשרות. הכיול מחלק את גודל
  /// הקובץ בסך השורות, כך שהוא נשאר נכון גם כשהמסד גדל בין גרסאות.
  _SizeCalibration _calibrate(sqlite3.Database db) {
    final pageCount = db.select('PRAGMA page_count').first.values.first as int;
    final pageSize = db.select('PRAGMA page_size').first.values.first as int;
    final totalBytes = pageCount * pageSize;

    final sum = db.select('SELECT SUM(totalLines) s FROM book').first['s'];
    final totalLines = (sum as num?)?.toInt() ?? 0;

    // ‏schema_meta, category, author וחבריהן נשארים במלואם בכל תת-קבוצה.
    // הרצפה הזו נמדדה על מסד סכמה 5 (~20MB) ומוחזקת כקבוע: היא קטנה
    // מכדי להצדיק שאילתת dbstat, שהיא סריקה מלאה.
    const globalFloorBytes = 20 * 1024 * 1024;

    final bytesPerLine =
        totalLines > 0 ? (totalBytes - globalFloorBytes) / totalLines : 0.0;
    return _SizeCalibration(
      bytesPerLine: bytesPerLine < 0 ? 0 : bytesPerLine,
      globalFloorBytes: globalFloorBytes,
    );
  }

  int _estimateBytes(sqlite3.Database db, _SizeCalibration cal) {
    final sum = db
        .select('SELECT SUM(totalLines) s FROM book '
            'WHERE id IN (${KeepSet.selectIds})')
        .first['s'];
    final lines = (sum as num?)?.toInt() ?? 0;
    final content = lines * cal.bytesPerLine * sizeSafetyFactor;
    return cal.globalFloorBytes + content.round();
  }

  /// כמה קישורים ייפלו כי צד אחד שלהם מחוץ לבחירה.
  ///
  /// מדיניות הניתוק היא סימטרית: קישור נשמר רק כששני צדיו בבחירה, ולכן
  /// גם קישור *נכנס* מספר שלא נבחר נחשב מנותק.
  int _countSeveredLinks(sqlite3.Database db) {
    final row = db
        .select(
          'SELECT COUNT(*) c FROM link '
          'WHERE (sourceBookId IN (${KeepSet.selectIds}) '
          '       AND targetBookId NOT IN (${KeepSet.selectIds})) '
          '   OR (targetBookId IN (${KeepSet.selectIds}) '
          '       AND sourceBookId NOT IN (${KeepSet.selectIds}))',
        )
        .first;
    return row['c'] as int;
  }

  /// הספרים שמחוץ לבחירה שהקישורים מצביעים אליהם, הכבדים ראשונים.
  List<SeveredLinkTarget> _severedTargets(
    sqlite3.Database db,
    _SizeCalibration cal,
    int limit,
  ) {
    // ה-UNION ALL מאחד את שני הכיוונים לעמודה אחת של "הספר שבחוץ",
    // וה-GROUP BY שאחריו סופר אותם יחד — קישור נכנס ויוצא לאותו ספר
    // מצטברים לשורה אחת.
    final rows = db.select(
      'WITH outside AS ('
      '  SELECT targetBookId AS bookId FROM link '
      '  WHERE sourceBookId IN (${KeepSet.selectIds}) '
      '    AND targetBookId NOT IN (${KeepSet.selectIds}) '
      '  UNION ALL '
      '  SELECT sourceBookId AS bookId FROM link '
      '  WHERE targetBookId IN (${KeepSet.selectIds}) '
      '    AND sourceBookId NOT IN (${KeepSet.selectIds})'
      ') '
      'SELECT o.bookId, COUNT(*) AS n, '
      '       COALESCE(b.title, \'\') AS title, '
      '       COALESCE(b.totalLines, 0) AS lines '
      'FROM outside o LEFT JOIN book b ON b.id = o.bookId '
      'GROUP BY o.bookId ORDER BY n DESC LIMIT ?',
      [limit],
    );

    return [
      for (final row in rows)
        SeveredLinkTarget(
          bookId: row['bookId'] as int,
          title: row['title'] as String,
          linkCount: row['n'] as int,
          estimatedBytes:
              ((row['lines'] as int) * cal.bytesPerLine * sizeSafetyFactor)
                  .round(),
        ),
    ];
  }
}

class _SizeCalibration {
  final double bytesPerLine;
  final int globalFloorBytes;

  const _SizeCalibration({
    required this.bytesPerLine,
    required this.globalFloorBytes,
  });
}

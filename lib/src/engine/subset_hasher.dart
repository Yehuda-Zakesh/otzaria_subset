import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// מחשב hash לוגי של מסד **חלקי**.
///
/// משתמש ב-`LogicalContentHasher` של החבילה המעדכנת ולא במימוש משלו: זרם
/// הבתים שם הוא תרגום בית-בית של הצד הקוטליני, ומימוש מקביל היה נסחף
/// ממנו. אותו אלגוריתם בדיוק, על פחות שורות.
///
/// ## מה ה-hash הזה כן עושה, ומה הוא לא
///
/// **כן:** מזהה שהמסד החלקי אצל המשתמש הוא בדיוק מה שהיה בסוף העדכון
/// הקודם. סחף, שחיתות, החלה חלקית שנקטעה באמצע, או patch שהוחל פעמיים —
/// כולם משנים אותו.
///
/// **לא:** אינו מוכיח שהמסנן צודק. הוא מגבב את מה שיש, לא את מה שהיה
/// צריך להיות. ההוכחה היחידה לנכונות המסנן היא מבחן השקילות
/// (`tool/equivalence_check.dart`), שמשווה תת-קבוצה שנבנתה מהמסד המלא
/// **אחרי** ההחלה מול תת-קבוצה שהוחל עליה patch מסונן.
///
/// **ולא:** אינו בר-השוואה ל-`fromContentHash`/`toContentHash` של אוצריא.
/// מסד חלקי לא יתאים להם לעולם. הקידומת ב-[compute] קיימת כדי שערך כזה
/// לא ייכנס בטעות לשדה שמצפה ל-hash של אפסטרים.
class SubsetHasher {
  final LogicalContentHasher _hasher;

  const SubsetHasher({LogicalContentHasher hasher = const LogicalContentHasher()})
      : _hasher = hasher;

  /// הקידומת שמסמנת "זה hash של מסד חלקי".
  static const String prefix = 'subset';

  /// מגבב את [db] לפי סדר הטבלאות של [schemaVersion].
  ///
  /// התוצאה בפורמט `subset:v<schema>:<hex>`. סכמה שאין לה סדר hash זורקת —
  /// גיבוב בסדר של סכמה אחרת מחזיר ערך שנראה תקין ואינו תקין.
  String compute(
    sqlite3.Database db, {
    required int schemaVersion,
    void Function(int bytesHashed)? onProgress,
  }) {
    final order = _orderFor(schemaVersion);
    final hex = _hasher.compute(db, tableOrder: order, onProgress: onProgress);
    return '$prefix:v$schemaVersion:$hex';
  }

  /// האם [value] הוא hash של תת-קבוצה (ולא של מסד מלא).
  static bool isSubsetHash(String? value) =>
      value != null && value.startsWith('$prefix:');

  List<String> _orderFor(int schemaVersion) {
    const orders = <int, List<String>>{
      1: kHashTableOrderSchema1,
      2: kHashTableOrderSchema2,
      3: kHashTableOrderSchema3,
      4: kHashTableOrderSchema4,
      // סכמה 5 שינתה עמודה בתוך line_dh ולא את סדר הטבלאות.
      5: kHashTableOrderSchema4,
    };
    final order = orders[schemaVersion];
    if (order == null) {
      throw ArgumentError.value(
        schemaVersion,
        'schemaVersion',
        'אין סדר hash לסכמה הזו — לא ניתן לגבב מסד חלקי בסכמה שאינה מוכרת',
      );
    }
    return order;
  }
}

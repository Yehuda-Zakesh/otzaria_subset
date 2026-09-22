import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:zstandard_native/zstandard_native.dart';

/// נזרק כשפירוק ה-zstd נכשל או בוטל.
class ZstdStreamException implements Exception {
  final String message;
  const ZstdStreamException(this.message);
  @override
  String toString() => 'ZstdStreamException: $message';
}

/// מפרק ארכיון zstd **בהזרמה**, מקובץ לקובץ.
///
/// ## למה לא פירוק חד-פעמי
///
/// הארכיון של הספרייה המלאה הוא ~1.5GB דחוס ו-~7.4GB מפורק. פירוק
/// חד-פעמי (`Zstandard().decompress`) מחזיק את שניהם בזיכרון — כלומר
/// קריסה על כל מחשב סביר. כאן עוברים במאגרים בגודל שמומלץ על ידי
/// ‏libzstd עצמה, והתפוסה נשארת בודדי מגהבייטים.
///
/// הלולאה זהה לזו שב-`library_manager`, שאינה מיוצאת משם.
abstract final class ZstdFileStream {
  /// שם ה-DLL שתוסף `zstandard` מניח ליד ה-exe בבנייה ל-Windows.
  static const String _windowsLibrary = 'zstandard_windows.dll';

  /// האם פירוק בהזרמה זמין כאן. `false` פירושו שצריך מסלול אחר —
  /// ולא שהקובץ פגום.
  static bool get isAvailable => bindingsOrNull() != null;

  static ZstandardNativeBindings? bindingsOrNull() {
    try {
      if (Platform.isWindows) {
        return ZstandardNativeBindings(DynamicLibrary.open(_windowsLibrary));
      }
      if (Platform.isMacOS) {
        return ZstandardNativeBindings(DynamicLibrary.open('zstandard_macos'));
      }
      return ZstandardNativeBindings(DynamicLibrary.open('libzstandard.so'));
    } catch (_) {
      return null;
    }
  }

  /// הגודל המפורק כפי שהוא רשום בכותרת ה-frame, בלי לפרק.
  ///
  /// משמש לבדיקת מקום פנוי **לפני** שמתחילים — גילוי שאין מקום אחרי
  /// שעתיים של פירוק הוא בדיוק מה שאסור לקרות כאן.
  static int? contentSizeOf(String sourcePath) {
    final bindings = bindingsOrNull();
    if (bindings == null) return null;
    final file = File(sourcePath);
    if (!file.existsSync()) return null;
    final head = file.openSync();
    final buffer = malloc.allocate<Uint8>(18);
    try {
      final bytes = head.readSync(18);
      if (bytes.isEmpty) return null;
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      final size =
          bindings.ZSTD_getFrameContentSize(buffer.cast(), bytes.length);
      // ‏0 ומעלה הוא גודל; הערכים המיוחדים (unknown/error) חורגים מעבר
      // לכל גודל קובץ סביר ולכן נדחים כאן.
      if (size <= 0 || size > (1 << 62)) return null;
      return size;
    } catch (_) {
      return null;
    } finally {
      malloc.free(buffer);
      head.closeSync();
    }
  }

  /// מפרק את [sourcePath] אל [destPath]. מחזיר `false` כשהפירוק
  /// בהזרמה אינו זמין בפלטפורמה הזו.
  ///
  /// רץ ב-`Isolate` משלו — הלולאה חוסמת לדקות ארוכות.
  static Future<bool> decompressFileToFile(
    String sourcePath,
    String destPath, {
    void Function(int bytesRead, int totalBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!isAvailable) return false;
    final total = File(sourcePath).lengthSync();

    // דגל ביטול כבייט בזיכרון מקורי: closure אינו עובר גבול isolate,
    // וכתובת היא הדבר היחיד שאפשר לשלוח ושהלולאה יכולה לבדוק.
    final cancelFlag = malloc.allocate<Uint8>(1);
    cancelFlag.value = 0;
    final progress = ReceivePort();
    progress.listen((Object? message) {
      if (message is int) onProgress?.call(message, total);
    });
    final poll = isCancelled == null
        ? null
        : Stream<void>.periodic(const Duration(milliseconds: 200)).listen((_) {
            if (isCancelled()) cancelFlag.value = 1;
          });

    try {
      await Isolate.run(() => _decompress(
            sourcePath,
            destPath,
            cancelFlag.address,
            progress.sendPort,
          ));
      return true;
    } finally {
      await poll?.cancel();
      progress.close();
      malloc.free(cancelFlag);
    }
  }
}

/// הלולאה עצמה. פונקציה גלובלית שמקבלת פרימיטיבים בלבד — ראו §9
/// ב-AGENTS.md.
void _decompress(
  String sourcePath,
  String destPath,
  int cancelFlagAddress,
  SendPort progress,
) {
  final bindings = ZstdFileStream.bindingsOrNull();
  if (bindings == null) {
    throw const ZstdStreamException('ספריית zstd אינה זמינה');
  }
  final cancelFlag = Pointer<Uint8>.fromAddress(cancelFlagAddress);
  final inSize = bindings.ZSTD_DStreamInSize();
  final outSize = bindings.ZSTD_DStreamOutSize();
  final inBuffer = malloc.allocate<Uint8>(inSize);
  final outBuffer = malloc.allocate<Uint8>(outSize);
  final input = malloc<ZSTD_inBuffer>();
  final output = malloc<ZSTD_outBuffer>();
  final dctx = bindings.ZSTD_createDCtx();
  final source = File(sourcePath).openSync();
  final dest = File(destPath).openSync(mode: FileMode.write);

  try {
    if (dctx == nullptr) {
      throw const ZstdStreamException('יצירת הקשר הפירוק נכשלה');
    }
    bindings.ZSTD_initDStream(dctx);
    // חלון גדול: ארכיון שנדחס עם חלון רחב אינו נפתח בלי זה.
    bindings.ZSTD_DCtx_setParameter(
      dctx,
      ZSTD_dParameter.ZSTD_d_windowLogMax,
      31,
    );

    var read = 0;
    final chunk = Uint8List(inSize);
    while (true) {
      if (cancelFlag.value != 0) {
        throw const ZstdStreamException('הפירוק בוטל');
      }
      final count = source.readIntoSync(chunk);
      if (count <= 0) break;
      read += count;
      inBuffer.asTypedList(count).setAll(0, chunk.sublist(0, count));
      input.ref
        ..src = inBuffer.cast()
        ..size = count
        ..pos = 0;
      while (input.ref.pos < input.ref.size) {
        output.ref
          ..dst = outBuffer.cast()
          ..size = outSize
          ..pos = 0;
        final code = bindings.ZSTD_decompressStream(dctx, output, input);
        if (bindings.ZSTD_isError(code) != 0) {
          throw const ZstdStreamException('הארכיון פגום או קטוע');
        }
        if (output.ref.pos > 0) {
          dest.writeFromSync(outBuffer.asTypedList(output.ref.pos));
        }
      }
      progress.send(read);
    }
  } finally {
    if (dctx != nullptr) bindings.ZSTD_freeDCtx(dctx);
    malloc.free(inBuffer);
    malloc.free(outBuffer);
    malloc.free(input);
    malloc.free(output);
    source.closeSync();
    dest.closeSync();
  }
}

/// מפרק zstd **מזרם** אל קובץ, בלי שהארכיון הדחוס ינחת על הדיסק.
///
/// ## למה זה קיים
///
/// הארכיון של הספרייה המלאה הוא ~1.5GB. המשתמש גזם מלכתחילה מפני שאין
/// לו מקום, והנחתת הארכיון לפני הפירוק הייתה מוסיפה 1.5GB לשיא התפוסה
/// בדיוק במסלול שבו הוא הכי צפוף. כאן כל מנה עוברת מהרשת ישר למפרק.
///
/// רץ ב-isolate הקורא ולא בנפרד: זרם אינו עובר גבול isolate עם
/// backpressure, ופירוק מנה של ~128KB הוא מילישניות בודדות — ה-UI מקבל
/// שליטה בחזרה בין מנה למנה.
Future<void> decompressStreamToFile(
  Stream<List<int>> source,
  String destPath, {
  void Function(int compressedBytes)? onProgress,
  bool Function()? isCancelled,
}) async {
  final bindings = ZstdFileStream.bindingsOrNull();
  if (bindings == null) {
    throw const ZstdStreamException('ספריית zstd אינה זמינה');
  }
  final outSize = bindings.ZSTD_DStreamOutSize();
  final outBuffer = malloc.allocate<Uint8>(outSize);
  var inBuffer = nullptr as Pointer<Uint8>;
  var inCapacity = 0;
  final input = malloc<ZSTD_inBuffer>();
  final output = malloc<ZSTD_outBuffer>();
  final dctx = bindings.ZSTD_createDCtx();
  final dest = File(destPath).openSync(mode: FileMode.write);
  var read = 0;

  try {
    if (dctx == nullptr) {
      throw const ZstdStreamException('יצירת הקשר הפירוק נכשלה');
    }
    bindings.ZSTD_initDStream(dctx);
    bindings.ZSTD_DCtx_setParameter(
      dctx,
      ZSTD_dParameter.ZSTD_d_windowLogMax,
      31,
    );

    await for (final chunk in source) {
      if (isCancelled?.call() ?? false) {
        throw const ZstdStreamException('הפירוק בוטל');
      }
      if (chunk.isEmpty) continue;
      // המאגר גדל לפי המנה הגדולה שראינו ואינו מוקצה מחדש בכל מנה —
      // הקצאה לכל מנה הייתה הפעולה היקרה ביותר בלולאה.
      if (chunk.length > inCapacity) {
        if (inBuffer != nullptr) malloc.free(inBuffer);
        inBuffer = malloc.allocate<Uint8>(chunk.length);
        inCapacity = chunk.length;
      }
      inBuffer.asTypedList(chunk.length).setAll(0, chunk);
      read += chunk.length;
      input.ref
        ..src = inBuffer.cast()
        ..size = chunk.length
        ..pos = 0;
      while (input.ref.pos < input.ref.size) {
        output.ref
          ..dst = outBuffer.cast()
          ..size = outSize
          ..pos = 0;
        final code = bindings.ZSTD_decompressStream(dctx, output, input);
        if (bindings.ZSTD_isError(code) != 0) {
          throw const ZstdStreamException('הארכיון פגום או קטוע');
        }
        if (output.ref.pos > 0) {
          dest.writeFromSync(outBuffer.asTypedList(output.ref.pos));
        }
      }
      onProgress?.call(read);
    }
  } finally {
    if (dctx != nullptr) bindings.ZSTD_freeDCtx(dctx);
    if (inBuffer != nullptr) malloc.free(inBuffer);
    malloc.free(outBuffer);
    malloc.free(input);
    malloc.free(output);
    dest.closeSync();
  }
}

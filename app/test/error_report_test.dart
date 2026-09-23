import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_subset_app/services/error_report.dart';

void main() {
  const home = r'C:\Users\Some User';

  test('מסתיר נתיב Windows רגיל', () {
    expect(
      maskPaths(r'open C:\Users\Some User\AppData\x.db failed', home: home),
      r'open %USERPROFILE%\AppData\x.db failed',
    );
  });

  test('מסתיר גם עם / וגם עם מפריד כפול', () {
    expect(maskPaths('C:/Users/Some User/x', home: home), '%USERPROFILE%/x');
    expect(
      maskPaths(r'"C:\Users\Some User\x"', home: home),
      r'"%USERPROFILE%\x"',
    );
  });

  test('אינו רגיש לרישיות', () {
    expect(maskPaths(r'c:\users\some user\x', home: home), r'%USERPROFILE%\x');
  });
}

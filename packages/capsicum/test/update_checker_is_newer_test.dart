// `UpdateChecker.isNewer` の semver 比較 contract test (#641)。
// 直配チャネル (Linux AppImage) の新版検知で、GitHub Release タグ (latest) と
// pubspec の現行バージョン (current) を比較する。ビルド番号 (`+` 以降) は
// 無視し、桁数違いは欠けた桁を 0 とみなす。
import 'package:capsicum/src/service/update_checker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UpdateChecker.isNewer — 新版検知の semver 比較 (#641)', () {
    test('patch / minor / major が上がっていれば true', () {
      expect(UpdateChecker.isNewer('1.29.1', '1.29.0'), isTrue);
      expect(UpdateChecker.isNewer('1.30.0', '1.29.0'), isTrue);
      expect(UpdateChecker.isNewer('2.0.0', '1.29.0'), isTrue);
    });

    test('同値は false (出さない)', () {
      expect(UpdateChecker.isNewer('1.29.0', '1.29.0'), isFalse);
    });

    test('current の方が新しければ false', () {
      expect(UpdateChecker.isNewer('1.29.0', '1.30.0'), isFalse);
      expect(UpdateChecker.isNewer('1.29.0', '1.29.1'), isFalse);
    });

    test('ビルド番号 (+N) は無視する — x.y.z 同値なら build 差は false', () {
      // pubspec は `1.29.0+85` 形式、GitHub tag は `1.29.0`。
      expect(UpdateChecker.isNewer('1.29.0', '1.29.0+85'), isFalse);
      expect(UpdateChecker.isNewer('1.29.0+90', '1.29.0+85'), isFalse);
      // x.y.z が上がっていれば build 番号に関係なく true。
      expect(UpdateChecker.isNewer('1.30.0', '1.29.0+85'), isTrue);
    });

    test('桁数違いは欠けた桁を 0 とみなす', () {
      // `1.30` (tag) vs `1.30.0` (current) は同値扱い。
      expect(UpdateChecker.isNewer('1.30', '1.30.0'), isFalse);
      expect(UpdateChecker.isNewer('1.30.0', '1.30'), isFalse);
      // `1.30.1` vs `1.30` は新版。
      expect(UpdateChecker.isNewer('1.30.1', '1.30'), isTrue);
    });

    test('数値以外の桁は 0 にフォールバック (異常タグでも誤検知しない)', () {
      expect(UpdateChecker.isNewer('1.x.0', '1.0.0'), isFalse);
    });
  });
}

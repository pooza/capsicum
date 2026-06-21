import 'package:capsicum/src/ui/screen/compose_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildMfmInsertion — MFM 装飾挿入のオフセット正規化 (#688 / #745)', () {
    test('前向き選択（base < extent）は選択範囲を囲む', () {
      final r = buildMfmInsertion('hello world', 6, 11, 'blur');
      expect(r.text, r'hello $[blur world]');
      // 末尾 `]` の後ろ（= 挿入末尾）にキャレット。
      expect(r.caret, r'hello $[blur world]'.length);
    });

    test('REPRO: 後ろ向き選択（base > extent）でも RangeError を投げず囲む', () {
      // 右→左ドラッグで base=11, extent=6 になるケース。
      final r = buildMfmInsertion('hello world', 11, 6, 'blur');
      expect(r.text, r'hello $[blur world]');
      expect(r.caret, r'hello $[blur world]'.length);
    });

    test('選択なし（collapsed caret）はタグだけ挿入しキャレットを閉じ括弧手前へ', () {
      final r = buildMfmInsertion('ab', 1, 1, 'x2');
      expect(r.text, r'a$[x2 ]b');
      // 閉じ `]` の手前 = `$[x2 ` の末尾。
      expect(r.caret, r'a$[x2 '.length);
    });

    test('選択なし（offset == -1）は末尾に挿入する', () {
      final r = buildMfmInsertion('abc', -1, -1, 'x2');
      expect(r.text, r'abc$[x2 ]');
      expect(r.caret, r'abc$[x2 '.length);
    });
  });
}

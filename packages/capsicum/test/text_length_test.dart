import 'package:capsicum/src/util/text_length.dart';
// ⚠ `characters` は flutter が再輸出しているものを使う（直接依存にすると
// pubspec を触ることになる）。ここでは「書記素との差」を示すためだけに要る。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1027-F2: 文字数の数え方がサーバーと食い違っていた。
///
/// | 数え方 | 使っていた場所 |
/// | --- | --- |
/// | `String.length`（UTF-16 コードユニット） | 本文カウンタ |
/// | `String.characters.length`（書記素） | Flutter の `maxLength` カウンタ・ALT 判定 |
/// | `String.runes.length`（コードポイント） | **サーバー** |
///
/// 実害:
///
/// - **ALT** … 書記素で数えると「512/512 なのにサーバーが 400」。Misskey の
///   `comment` は JSON Schema `maxLength: 512` + DB `varchar(512)` でどちらも
///   コードポイント
/// - **本文** … UTF-16 で数えると必要以上に赤くなる（絵文字 1 個が 2 と数えられる）
void main() {
  group('serverTextLength', () {
    test('日本語・英字はどの数え方でも同じ', () {
      expect(serverTextLength('abc'), 3);
      expect(serverTextLength('あいう'), 3);
      expect(serverTextLength(''), 0);
    });

    // ⚠ ここが分かれ目。BMP 外の絵文字は UTF-16 で 2 コードユニット。
    test('サロゲートペアの絵文字は 1 と数える', () {
      expect('😀'.length, 2, reason: '前提: String.length は UTF-16');
      expect(serverTextLength('😀'), 1);
    });

    // ⚠⚠ **書記素との差が最大になる形。**家族絵文字は ZWJ で 4 つの絵文字を
    // 繋いだもので、書記素 1・コードポイント 7。書記素で数えると 512 個まで
    // 通してしまい、サーバーは 3584 と数えて弾く。
    test('ZWJ の合字は結合前の数で数える', () {
      const family = '👨‍👩‍👧‍👦';
      expect(family.characters.length, 1, reason: '前提: 書記素は 1');
      expect(serverTextLength(family), 7);
    });

    test('国旗（地域指示子 2 つ）は 2', () {
      expect(serverTextLength('🇯🇵'), 2);
    });

    test('結合文字は分けて数える', () {
      // e + U+0301（合成用アキュート）。見た目は 1 文字。
      expect(serverTextLength('é'), 2);
    });

    test('改行・空白も 1 文字', () {
      expect(serverTextLength('a\nb'), 3);
      expect(serverTextLength(' '), 1);
    });
  });
}

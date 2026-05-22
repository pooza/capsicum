import 'package:capsicum/src/ui/screen/compose_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// #581 観点1: 投稿フォームの補完トリガ判定。旧実装は半角空白 / 改行 / 文頭
/// のみを境界としていたため、日本語の「。@user」「）#tag」全角空白・タブ等
/// の直後でサジェストが不発だった。境界を「語字以外」に拡張しつつ、
/// `foo@bar`(メール) や `12:34`(時刻) を誤発火しない意図は維持する。

String? q(String text, {int? cursor, String trigger = '@'}) =>
    composeTriggerQuery(
      text: text,
      cursor: cursor ?? text.length,
      trigger: trigger,
    );

void main() {
  group('composeTriggerQuery — 既存挙動の維持', () {
    test('文頭トリガ', () => expect(q('@bob'), 'bob'));
    test('半角空白の直後', () => expect(q('hi @bob'), 'bob'));
    test('改行の直後', () => expect(q('hi\n@bob'), 'bob'));
    test('ハッシュタグ', () => expect(q('見て #実況', trigger: '#'), '実況'));
    test('カーソル途中まで', () => expect(q('@abcd', cursor: 3), 'ab'));
    test('トリガ直後（空クエリ）は null', () => expect(q('@'), isNull));
    test('クエリ内の半角空白で打ち切り', () => expect(q('@foo bar'), isNull));

    test('メール foo@bar は誤発火しない（直前が英字）', () {
      expect(q('foo@bar'), isNull);
    });
    test('時刻 12:34 は誤発火しない（直前が数字）', () {
      expect(q('12:34', trigger: ':'), isNull);
    });
    test('カーソル範囲外は null', () {
      expect(q('@bob', cursor: -1), isNull);
      expect(q('@bob', cursor: 99), isNull);
    });
  });

  group('composeTriggerQuery — #581 観点1 で拡張した境界', () {
    test('全角空白の直後で発火', () {
      expect(q('あ　@bob'), 'bob');
    });
    test('句点の直後で発火', () {
      expect(q('おわり。@user'), 'user');
    });
    test('全角閉じ括弧の直後でハッシュタグ発火', () {
      expect(q('（メモ）#tag', trigger: '#'), 'tag');
    });
    test('タブの直後で発火', () {
      expect(q('a\t@x'), 'x');
    });
    test('半角括弧の直後で絵文字トリガ発火', () {
      expect(q('(:smile', trigger: ':'), 'smile');
    });
    test('全角空白はクエリ区切りとしても機能する', () {
      expect(q('@foo　bar'), isNull);
    });
  });
}

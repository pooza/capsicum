import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';

/// #944: 「非推奨」を含むカテゴリの絵文字を新規入力の導線から外す。
///
/// 判定は `CustomEmoji.offeredForInput` に集約してあり、ピッカー本体
/// (`emoji_picker.dart`) と `:` ショートコード補完 (`compose_screen.dart`) が
/// 共有する。**どちらか片方だけ直す**のが起きやすい壊れ方なので、条件そのものを
/// ここで固定する。
void main() {
  CustomEmoji emoji({String? category, bool visibleInPicker = true}) =>
      CustomEmoji(
        shortcode: 'gome',
        url: 'https://example.test/gome.png',
        category: category,
        visibleInPicker: visibleInPicker,
      );

  group('CustomEmoji.offeredForInput', () {
    test('カテゴリなしは出す', () {
      expect(emoji().offeredForInput, isTrue);
      expect(emoji(category: '').offeredForInput, isTrue);
    });

    test('無関係なカテゴリは出す', () {
      expect(emoji(category: 'ゴメちゃん').offeredForInput, isTrue);
    });

    test('カテゴリ名に「非推奨」を含めば出さない', () {
      expect(emoji(category: '非推奨').offeredForInput, isFalse);
    });

    test('部分一致なので表記ゆれを吸収する', () {
      // デルムリン丼 / キュアスタ！で実際に食い違っている 2 つ。
      expect(emoji(category: '旧コードのため非推奨').offeredForInput, isFalse);
      expect(emoji(category: '旧コードの為非推奨').offeredForInput, isFalse);
      // サーバー側が将来改名しても、この語を残す限り追従する。
      expect(emoji(category: '【非推奨】旧ショートコード').offeredForInput, isFalse);
    });

    test('visible_in_picker=false は従来どおり出さない (#622)', () {
      expect(emoji(visibleInPicker: false).offeredForInput, isFalse);
      expect(
        emoji(category: 'ゴメちゃん', visibleInPicker: false).offeredForInput,
        isFalse,
      );
    });
  });
}

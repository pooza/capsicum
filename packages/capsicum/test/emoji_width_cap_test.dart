import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:capsicum/src/ui/widget/emoji_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #858: 本文中のカスタム絵文字に「幅は高さの N 倍」という固定 cap を置かない
/// ことを担保する。
///
/// かつて `maxWidth: emojiSize * 3` があり、3:1 を超える横長絵文字が
/// `BoxFit.contain` で細い帯に潰れていた（ダイスキー実測で 7.7% が該当・最長
/// 9.85:1 のテキストバナー系）。幅の頭打ちは `WidgetSpan` の子に
/// `RenderParagraph` が渡す `BoxConstraints(maxWidth: 段落の利用可能幅)` に
/// 任せる設計で、`ConstrainedBox` 側は maxHeight だけを課す。
///
/// 「オーバーフローが怖いから」と固定 cap を戻すと同じ潰れが再発するため、
/// 2 箇所（content_parser / emoji_text）とも cap 無しであることを固定する。
void main() {
  setUp(() {
    // EmojiSizeNotifier.build() は defaultEmojiSize を同期で返し、保存値の
    // 読み込みだけ非同期で行う。空の mock を挿して既定値のまま走らせる。
    SharedPreferences.setMockInitialValues({});
  });

  /// 絵文字画像を包む最も内側の [ConstrainedBox] を取り出す。
  ///
  /// テスト環境の `Image.network` は 400 を返して errorBuilder に落ちるが、
  /// `Image` widget 自体はツリーに残るため ancestor で辿れる。
  BoxConstraints emojiConstraints(WidgetTester tester) {
    final finder = find
        .ancestor(of: find.byType(Image), matching: find.byType(ConstrainedBox))
        .first;
    return tester.widget<ConstrainedBox>(finder).constraints;
  }

  Widget wrap(Widget child) {
    return ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          // 実際の投稿タイルに近い有限幅。ここが幅の頭打ちを担う。
          body: SizedBox(width: 320, child: child),
        ),
      ),
    );
  }

  testWidgets('content_parser: 本文中の絵文字に固定の幅 cap を置かない', (tester) async {
    final renderer = ContentRenderer(
      baseStyle: const TextStyle(fontSize: 14),
      resolveEmoji: (name) => 'https://example.test/emoji/$name.webp',
    );
    addTearDown(renderer.dispose);

    await tester.pumpWidget(
      wrap(Text.rich(renderer.renderMfm('a :banner: b'))),
    );

    final constraints = emojiConstraints(tester);
    expect(constraints.maxHeight, 20.0);
    expect(
      constraints.maxWidth,
      double.infinity,
      reason: '幅は段落の利用可能幅に委ねる。固定 cap を置くと横長絵文字が潰れる (#858)',
    );
  });

  testWidgets('emoji_text: 表示名等の絵文字に固定の幅 cap を置かない', (tester) async {
    await tester.pumpWidget(
      wrap(
        const EmojiText(
          'name :banner: suffix',
          emojis: {'banner': 'https://example.test/emoji/banner.webp'},
        ),
      ),
    );

    final constraints = emojiConstraints(tester);
    expect(constraints.maxHeight, 20.0);
    expect(
      constraints.maxWidth,
      double.infinity,
      reason: 'content_parser 側と挙動を揃える (#858)',
    );
  });
}

import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:capsicum/src/ui/widget/emoji_text.dart';
import 'package:capsicum/src/ui/widget/inline_custom_emoji.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1032: 本文中のカスタム絵文字が「デコードが済むまで幅 0」になるのを潰す。
///
/// 幅を渡さない `Image` は `RenderImage._sizeForConstraints` が
/// `constraints.smallest` を返すため、デコード前の幅が 0 になる。デコード後に
/// 実寸へ跳ねると `Text.rich` の折り返し＝行数が変わり、投稿タイルの高さが動く。
/// `RenderSliverList` はビューポート外の高さを dead reckoning で持っているので、
/// 上へ戻ったときにその食い違いが `scrollOffsetCorrection` として出て、
/// スクロール位置が跳ねる。
///
/// ⚠ **#858 の「幅に固定 cap を置かない」とは両立する。**ここで固定するのは
/// 「幅を渡していること」であって上限ではない。`ConstrainedBox` 側が maxHeight
/// だけを課す点は [emoji_width_cap_test.dart] が別途担保している。
void main() {
  const url = 'https://example.test/emoji/banner.webp';

  group('EmojiAspectRatioCache', () {
    test('覚えた比を引ける', () {
      final cache = EmojiAspectRatioCache();
      cache.record(url, 9.85);
      expect(cache[url], 9.85);
      expect(cache['https://example.test/emoji/unknown.webp'], isNull);
    });

    test('レイアウトを壊す比は捨てる', () {
      final cache = EmojiAspectRatioCache();
      cache.record('$url#zero', 0);
      cache.record('$url#negative', -1);
      cache.record('$url#nan', double.nan);
      cache.record('$url#infinite', double.infinity);
      expect(
        cache.length,
        0,
        reason:
            '0 / 負 / NaN / Infinity を通すと size * ratio が BoxConstraints の '
            'assert で落ちる',
      );
    });

    test('上限を超えたぶんは最古から押し出す', () {
      final cache = EmojiAspectRatioCache(maxSize: 3);
      cache.record('a', 1);
      cache.record('b', 2);
      cache.record('c', 3);
      cache.record('d', 4);

      expect(cache.length, 3);
      expect(cache['a'], isNull, reason: '最古の a が押し出される');
      expect(cache['b'], 2);
      expect(cache['c'], 3);
      expect(cache['d'], 4);
    });

    test('既知の URL を再記録しても FIFO の位置は動かない', () {
      final cache = EmojiAspectRatioCache(maxSize: 2);
      cache.record('a', 1);
      cache.record('b', 2);
      // a を再記録。LRU なら a が最新へ動くが、ここは FIFO なので動かない。
      cache.record('a', 1);
      cache.record('c', 3);

      expect(cache['a'], isNull, reason: 'FIFO なので再記録しても最古のまま');
      expect(cache['b'], 2);
      expect(cache['c'], 3);
    });
  });

  group('InlineCustomEmoji', () {
    /// 絵文字画像の `Image` widget（設定値を読む）。
    ///
    /// テスト環境の `Image.network` は 400 を返して errorBuilder に落ちるが、
    /// `Image` widget 自体はツリーに残るため設定値は読める。
    Image emojiImage(WidgetTester tester) =>
        tester.widget<Image>(find.byType(Image).first);

    Widget wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SizedBox(width: 320, child: child)),
    );

    testWidgets('比が未知でも幅 0 にはせず、正方形ぶんを予約する', (tester) async {
      await tester.pumpWidget(
        wrap(const InlineCustomEmoji(url: url, shortcode: 'banner', size: 20)),
      );

      expect(
        emojiImage(tester).width,
        20.0,
        reason: '初見の絵文字は寸法が分からない。0 より実寸に近い正方形で置く',
      );
      expect(emojiImage(tester).height, 20.0);
    });

    testWidgets('比が既知なら最初のレイアウトから実寸の幅で置く', (tester) async {
      final cache = EmojiAspectRatioCache()..record(url, 9.85);

      await tester.pumpWidget(
        wrap(
          InlineCustomEmoji(
            url: url,
            shortcode: 'banner',
            size: 20,
            cache: cache,
          ),
        ),
      );

      expect(
        emojiImage(tester).width,
        20.0 * 9.85,
        reason:
            'デコード後に constrainSizeAndAttemptToPreserveAspectRatio が出す値と '
            '同じ幅を、デコード前から置く',
      );
    });

    testWidgets('幅の頭打ちは段落の利用可能幅に委ねたまま (#858)', (tester) async {
      final cache = EmojiAspectRatioCache()..record(url, 9.85);

      await tester.pumpWidget(
        wrap(
          InlineCustomEmoji(
            url: url,
            shortcode: 'banner',
            size: 20,
            cache: cache,
          ),
        ),
      );

      final box = tester.widget<ConstrainedBox>(
        find
            .ancestor(
              of: find.byType(Image),
              matching: find.byType(ConstrainedBox),
            )
            .first,
      );
      expect(box.constraints.maxHeight, 20.0);
      expect(
        box.constraints.maxWidth,
        double.infinity,
        reason: '幅の予約は Image 側で行う。ConstrainedBox に cap を戻すと横長絵文字が潰れる',
      );
    });

    testWidgets('リアクションチップ用に幅 cap を課せる (#924)', (tester) async {
      final cache = EmojiAspectRatioCache()..record(url, 9.85);

      await tester.pumpWidget(
        wrap(
          InlineCustomEmoji(
            url: url,
            shortcode: 'banner',
            size: 20,
            maxWidthFactor: 3,
            cache: cache,
          ),
        ),
      );

      final box = tester.widget<ConstrainedBox>(
        find
            .ancestor(
              of: find.byType(Image),
              matching: find.byType(ConstrainedBox),
            )
            .first,
      );
      expect(
        box.constraints.maxWidth,
        60.0,
        reason: 'チップは肥大化防止で 3 倍 cap を維持する。本文 (cap 無し) と別方針',
      );
      expect(
        emojiImage(tester).width,
        20.0 * 9.85,
        reason: '予約幅は実寸のまま渡し、頭打ちは ConstrainedBox の enforce に任せる',
      );
    });

    testWidgets('フォールバックを差し替えられる', (tester) async {
      await tester.pumpWidget(
        wrap(
          const InlineCustomEmoji(
            url: url,
            shortcode: 'banner',
            size: 20,
            fallback: Text('生キー'),
          ),
        ),
      );
      // テスト環境の Image.network は 400 を返して errorBuilder に落ちる。
      await tester.pump();

      expect(find.text('生キー'), findsOneWidget);
      expect(find.text(':banner:'), findsNothing);
    });
  });

  group('呼び出し側の 2 経路', () {
    setUp(() {
      // EmojiSizeNotifier.build() は defaultEmojiSize を同期で返し、保存値の
      // 読み込みだけ非同期で行う。空の mock を挿して既定値のまま走らせる。
      SharedPreferences.setMockInitialValues({});
      EmojiAspectRatioCache.instance.clear();
    });

    tearDown(EmojiAspectRatioCache.instance.clear);

    Widget wrap(Widget child) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: SizedBox(width: 320, child: child)),
      ),
    );

    testWidgets('content_parser: 覚えた比が本文の絵文字へ効く', (tester) async {
      EmojiAspectRatioCache.instance.record(url, 9.85);
      final renderer = ContentRenderer(
        baseStyle: const TextStyle(fontSize: 14),
        resolveEmoji: (_) => url,
      );
      addTearDown(renderer.dispose);

      await tester.pumpWidget(
        wrap(Text.rich(renderer.renderMfm('a :banner: b'))),
      );

      expect(tester.widget<Image>(find.byType(Image).first).width, 20.0 * 9.85);
    });

    testWidgets('emoji_text: 覚えた比が表示名の絵文字へ効く', (tester) async {
      EmojiAspectRatioCache.instance.record(url, 9.85);

      await tester.pumpWidget(
        wrap(const EmojiText('name :banner: suffix', emojis: {'banner': url})),
      );

      expect(tester.widget<Image>(find.byType(Image).first).width, 20.0 * 9.85);
    });
  });
}

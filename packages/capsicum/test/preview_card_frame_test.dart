import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/ui/widget/preview_card_widget.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1032 / #1033: プレビューカードが持っていた「枠が確定しない」2 経路を潰す。
///
/// カードは `Column` で組まれているため、**幅は子の最大幅で決まる**。横幅を
/// 広げていたのが `Image.network(width: double.infinity, ...)` だけだったので、
/// OGP 画像を持たない（または読み込みに失敗した）カードは本文なりに細くなり、
/// さらに `errorBuilder` が `SizedBox.shrink()` を返すことで高さ 160px も同時に
/// 失っていた。
///
/// 高さが揺れると `RenderSliverList` の未生成タイル高さ推定（生成済みタイルの
/// 平均 × 残り件数）がずれ、`scrollOffsetCorrection` としてスクロール位置の
/// 跳ねに化ける。**幅と高さは別々の症状ではなく同じ 1 行から出ていた**ので、
/// ここでは両方まとめて固定する。
///
/// ⚠ 「タイトルを長くすれば幅いっぱいになる」ので、幅の検査には**短い**
/// タイトルを使うこと。長いタイトルだと `Text` が勝手に広がり、幅指定を外して
/// も緑で通ってしまう。
void main() {
  const width = 320.0;

  /// 短いタイトル。幅指定が無ければカードが縮む側に倒れる。
  const shortCard = PreviewCard(
    url: 'https://example.test/page',
    title: '短い',
    description: '短い説明',
  );

  const imageCard = PreviewCard(
    url: 'https://example.test/page',
    title: '短い',
    description: '短い説明',
    imageUrl: 'https://example.test/ogp.png',
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// カードを **post_tile と同じ器**に置く。
  ///
  /// ⚠ `SizedBox(width: 320, child: card)` で包んではいけない。SizedBox は子へ
  /// **tight** な幅を渡すので、カード側の幅指定を外しても 320 のまま緑になる
  /// （#1033 を検査できない偽の緑）。実物は `Column(crossAxisAlignment: start)`
  /// の子で、渡ってくる幅は **loose**。高さも同じ理由で Column に委ねる
  /// （Scaffold の body 直下だと縦に引き伸ばされ、カードの実高が測れない）。
  Future<void> pumpCard(
    WidgetTester tester,
    PreviewCard card, {
    List<Override> overrides = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [PreviewCardWidget(card: card)],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Size cardSize(WidgetTester tester) =>
      tester.getSize(find.byType(PreviewCardWidget));

  group('幅 (#1033)', () {
    testWidgets('OGP 画像を持たないカードも幅いっぱいになる', (tester) async {
      await pumpCard(tester, shortCard);

      expect(
        cardSize(tester).width,
        width,
        reason:
            'Column の幅は子の最大幅で決まる。Container に width を渡さないと、'
            '横幅を広げる子（画像）が居ないカードだけ本文なりに縮む',
      );
    });

    testWidgets('OGP 画像の読み込みに失敗しても幅いっぱいのまま', (tester) async {
      await pumpCard(tester, imageCard);
      // テスト環境の Image.network は 400 を返して errorBuilder に落ちる。
      await tester.pump();

      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(cardSize(tester).width, width);
    });
  });

  group('高さ (#1032)', () {
    testWidgets('OGP 画像の読み込みに失敗しても高さが変わらない', (tester) async {
      await pumpCard(tester, imageCard);
      // 1 フレーム目は読み込み中。width / height を渡してあるので枠は 160px。
      final loading = cardSize(tester).height;
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);

      await tester.pump();

      expect(
        find.byIcon(Icons.broken_image_outlined),
        findsOneWidget,
        reason: 'errorBuilder に落ちていないと、この検査は何も見ていない',
      );
      expect(
        cardSize(tester).height,
        loading,
        reason:
            'errorBuilder が SizedBox.shrink() を返すと 160px が 0 に潰れる。'
            'タイル高さが揺れて RenderSliverList の推定がずれ、上へ戻るときの'
            'スクロール位置の跳ねになる (#1032)',
      );
    });

    testWidgets('失敗時のプレースホルダは 160px の枠を保つ', (tester) async {
      await pumpCard(tester, imageCard);
      await tester.pump();

      final placeholder = tester.getSize(
        find.byKey(PreviewCardWidget.imagePlaceholderKey),
      );
      expect(placeholder.height, PreviewCardWidget.imageHeight);
      expect(placeholder.width, width - 2, reason: 'カードの枠線 1px ぶんを差し引いた内側いっぱい');
    });

    testWidgets('画像を持たないカードは画像ぶんの枠を取らない', (tester) async {
      await pumpCard(tester, shortCard);
      final textOnly = cardSize(tester).height;

      await pumpCard(tester, imageCard);
      await tester.pump();
      final withImage = cardSize(tester).height;

      expect(
        withImage - textOnly,
        PreviewCardWidget.imageHeight,
        reason:
            '枠を保つのは「画像を出すつもりだったカード」だけ。画像を持たない'
            'カードにまで 160px を予約すると、ただの余白になる',
      );
    });
  });

  testWidgets('hide 設定では従来どおり何も描かない', (tester) async {
    await pumpCard(
      tester,
      shortCard,
      overrides: [
        previewCardModeProvider.overrideWith(_HiddenPreviewCardMode.new),
      ],
    );

    expect(cardSize(tester).height, 0);
    expect(find.text('短い'), findsNothing);
  });
}

class _HiddenPreviewCardMode extends PreviewCardModeNotifier {
  @override
  PreviewCardMode build() => PreviewCardMode.hide;
}

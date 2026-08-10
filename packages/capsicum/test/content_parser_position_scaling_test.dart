import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// #913: `$[position]` の em 換算を文字サイズ設定（textScaler）に追従させる。
///
/// グリフは `RenderParagraph` がレイアウト時に textScaler を掛けて描くので、
/// ずれ量だけ据え置かれると両者の比率が崩れる。本家 Misskey は CSS の `em` で、
/// 常に計算後のフォントサイズに追従する。
///
/// 倍率は `MediaQuery` から描画時に読むため、検証も実際にウィジェットを載せて
/// `Transform` の行列を見る（span の組み立てだけでは倍率が決まらない）。
void main() {
  ContentRenderer buildRenderer() => ContentRenderer(
    baseStyle: const TextStyle(fontSize: 14),
    resolveEmoji: (_) => null,
  );

  /// [scale] の文字サイズ設定で MFM を描き、`$[position]` が適用した平行移動量を返す。
  Future<Offset> translationAt(WidgetTester tester, double scale) async {
    final renderer = buildRenderer();
    addTearDown(renderer.dispose);

    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: Text.rich(renderer.renderMfm(r'$[position.x=2,y=3 ABC]')),
          ),
        ),
      ),
    );

    final transform = tester.widget<Transform>(find.byType(Transform));
    return Offset(
      transform.transform.getTranslation().x,
      transform.transform.getTranslation().y,
    );
  }

  testWidgets('等倍では宣言フォントサイズどおりに換算する', (tester) async {
    // 14 * 2 = 28、14 * 3 = 42。
    expect(await translationAt(tester, 1.0), const Offset(28, 42));
  });

  testWidgets('文字サイズ設定を上げるとずれ量も同じ倍率で追従する', (tester) async {
    // 140% ではグリフが 1.4 倍になるので、ずれ量も 1.4 倍でなければ比率が崩れる。
    expect(await translationAt(tester, 1.4), const Offset(28 * 1.4, 42 * 1.4));
  });

  testWidgets('文字サイズ設定を下げたときも追従する', (tester) async {
    expect(await translationAt(tester, 0.8), const Offset(28 * 0.8, 42 * 0.8));
  });
}

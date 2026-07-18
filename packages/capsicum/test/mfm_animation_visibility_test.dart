import 'package:capsicum/src/ui/widget/mfm_animation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// #845: MFM アニメーションの ticker が「実表示中だけ」回ることを担保する。
///
/// 実際の呼び出し側（content_parser）は `WidgetSpan` の中に `MfmAnimation` を
/// 置くため、テストも同じ形（RichText のインライン widget）で組む。ここが
/// 効かないと、v1.48 の目玉である #259 のアニメが画面外で回りっぱなしになる
/// （＝直そうとしている当の問題）か、逆に永久に止まったままになる。
///
/// ticker が回っているかは `transientCallbackCount`（フレームコールバックの
/// 登録数）で見る。controller を直接覗かずに済み、実装の内部に踏み込まない。
void main() {
  setUp(() {
    // 既定では最大 500ms に 1 回のバッチ通知。テストでは即時に届かせる。
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  tearDown(() {
    VisibilityDetectorController.instance.updateInterval = const Duration(
      milliseconds: 500,
    );
  });

  Widget buildListWithAnimationAt({
    required ScrollController controller,
    required int animatedIndex,
    required int itemCount,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: ListView.builder(
            controller: controller,
            itemCount: itemCount,
            itemBuilder: (context, index) => SizedBox(
              height: 300,
              child: index == animatedIndex
                  ? Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(text: 'before '),
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: MfmAnimation(
                              type: MfmAnimationType.spin,
                              fontSize: 14,
                              child: const Text('spin'),
                            ),
                          ),
                          const TextSpan(text: ' after'),
                        ],
                      ),
                    )
                  : Text('item $index'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('表示中は ticker が回る', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      buildListWithAnimationAt(
        controller: controller,
        animatedIndex: 0,
        itemCount: 4,
      ),
    );
    await tester.pump();

    expect(
      tester.binding.transientCallbackCount,
      greaterThan(0),
      reason: '表示中のアニメは再生されているべき',
    );
  });

  // #845 の本丸。破棄されるほど遠くへ送ると「widget が消えたから ticker も
  // 消えた」だけで通ってしまい、何も検証できない。ListView の cacheExtent
  // (既定 250px) の中＝**生きているが描画されない**位置に置いて、widget が
  // 残ったまま ticker だけ止まることを見る。
  testWidgets('cacheExtent 内で生存したまま画面外なら ticker が止まる', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      buildListWithAnimationAt(
        controller: controller,
        animatedIndex: 0,
        itemCount: 4,
      ),
    );
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    // viewport は 400-700。item 0 は 0-300 で、上に 100px ぶんだけ外れる
    // （cacheExtent 250 の内側なので破棄されない）。
    controller.jumpTo(400);
    await tester.pump();
    await tester.pump();

    expect(
      find.byType(MfmAnimation, skipOffstage: false),
      findsOneWidget,
      reason:
          'この位置では cacheExtent により widget は生存しているはず'
          '（破棄されていると ticker=0 が素通りして検証にならない）',
    );
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: '生きていても描画されていないなら ticker は止めているべき',
    );
  });

  testWidgets('破棄される距離までスクロールしても ticker は残らない', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      buildListWithAnimationAt(
        controller: controller,
        animatedIndex: 0,
        itemCount: 4,
      ),
    );
    await tester.pump();

    controller.jumpTo(900);
    await tester.pump();
    await tester.pump();

    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('画面外から戻すと ticker が再開する', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      buildListWithAnimationAt(
        controller: controller,
        animatedIndex: 0,
        itemCount: 4,
      ),
    );
    await tester.pump();

    controller.jumpTo(900);
    await tester.pump();
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);

    controller.jumpTo(0);
    await tester.pump();
    await tester.pump();

    expect(
      tester.binding.transientCallbackCount,
      greaterThan(0),
      reason: '戻ってきたら再生を再開するべき',
    );
  });

  testWidgets('reduce motion 時は表示中でも ticker を回さない', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: buildListWithAnimationAt(
          controller: controller,
          animatedIndex: 0,
          itemCount: 4,
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: 'reduce motion 時は静止表示で ticker も止める',
    );
  });
}

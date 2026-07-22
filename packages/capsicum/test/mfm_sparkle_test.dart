import 'package:capsicum/src/ui/widget/mfm_animation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// #863: `$[sparkle ...]` を対象の周囲にパーティクルを撒くアニメーションで表現。
///
/// 変形（[MfmAnimation]）でも前景色（rainbow）でも表現できないため、child の上に
/// [CustomPaint] のオーバーレイを重ねて星形パーティクルを描く。レイアウトを乱さない
/// こと、reduce motion / 画面外では ticker を止めることを担保する。
void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  tearDown(() {
    VisibilityDetectorController.instance.updateInterval = const Duration(
      milliseconds: 500,
    );
  });

  Widget host(Widget child, {bool reduceMotion = false}) {
    final tree = MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );
    if (!reduceMotion) return tree;
    return MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: tree,
    );
  }

  testWidgets('child の上にパーティクルの CustomPaint オーバーレイを重ねる', (tester) async {
    await tester.pumpWidget(
      host(
        const MfmSparkle(fontSize: 14, child: Text('きらきら', key: Key('body'))),
      ),
    );
    await tester.pump();

    // child（テキスト）は生きている。
    expect(find.byKey(const Key('body')), findsOneWidget);
    // オーバーレイの CustomPaint が child と同じ Stack 内にある。
    expect(
      find.descendant(
        of: find.byType(MfmSparkle),
        matching: find.byType(CustomPaint),
      ),
      findsWidgets,
    );
  });

  testWidgets('通常時は ticker が回る', (tester) async {
    await tester.pumpWidget(
      host(const MfmSparkle(fontSize: 14, child: Text('a'))),
    );
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });

  testWidgets('reduce motion 時はパーティクルを出さず child のみ・ticker も止める', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const MfmSparkle(fontSize: 14, child: Text('きらきら', key: Key('body'))),
        reduceMotion: true,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('body')), findsOneWidget);
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: 'reduce motion 時はアニメを止める',
    );
    // オーバーレイの Stack を組まないので、MfmSparkle 配下に CustomPaint は無い。
    expect(
      find.descendant(
        of: find.byType(MfmSparkle),
        matching: find.byType(CustomPaint),
      ),
      findsNothing,
    );
  });
}

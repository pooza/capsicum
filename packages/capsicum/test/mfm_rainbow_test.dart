import 'package:capsicum/src/ui/widget/mfm_animation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// #864: `$[rainbow ...]` を無彩色テキストでも虹色に見せる。
///
/// hue-rotate（旧実装）は彩度のある色にしか効かず、デフォルト色の本文では変化
/// しなかった。新実装ではテキストに虹グラデを **前景シェーダ**として与える一方、
/// カスタム絵文字などの [WidgetSpan] は虹でシルエット化させず hue-rotate で色相
/// だけ回す。この「テキスト＝グラデ / 絵文字＝hue-rotate」の使い分けを担保する。
void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  tearDown(() {
    VisibilityDetectorController.instance.updateInterval = const Duration(
      milliseconds: 500,
    );
  });

  /// 呼び出し側（content_parser）と同じく `WidgetSpan` に包んで RichText の
  /// インラインに置く。中身はテキストと「絵文字相当の WidgetSpan」の混在。
  Widget buildRainbow({bool reduceMotion = false}) {
    const key = Key('emoji');
    final tree = MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text.rich(
            TextSpan(
              children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: MfmRainbowText(
                    baseStyle: const TextStyle(
                      fontSize: 14,
                      color: Colors.grey,
                    ),
                    spans: const [
                      TextSpan(text: 'にじ'),
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: SizedBox(key: key, width: 10, height: 10),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!reduceMotion) return tree;
    return MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: tree,
    );
  }

  testWidgets('テキストには虹グラデを前景色として与える（color は消える）', (tester) async {
    await tester.pumpWidget(buildRainbow());
    await tester.pump();

    final textSpan = _findTextSpan(tester, 'にじ');
    expect(textSpan, isNotNull, reason: 'rainbow のテキスト span が要る');
    expect(
      textSpan!.style?.foreground,
      isNotNull,
      reason: 'テキストは虹グラデの前景シェーダを持つべき',
    );
    expect(
      textSpan.style?.color,
      isNull,
      reason: 'foreground を与えたら color は消えているべき（二重指定 assert 回避）',
    );
  });

  testWidgets('絵文字（WidgetSpan）は虹で潰さず hue-rotate で色相を回す', (tester) async {
    await tester.pumpWidget(buildRainbow());
    await tester.pump();

    // 絵文字の SizedBox の祖先に ColorFiltered（hue-rotate）が挟まっているべき。
    expect(
      find.ancestor(
        of: find.byKey(const Key('emoji')),
        matching: find.byType(ColorFiltered),
      ),
      findsOneWidget,
      reason: '絵文字は ColorFiltered（hue-rotate）でラップされるべき',
    );
  });

  testWidgets('通常時は ticker が回る', (tester) async {
    await tester.pumpWidget(buildRainbow());
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });

  testWidgets('reduce motion 時は ticker を止めても虹色は乗せる', (tester) async {
    await tester.pumpWidget(buildRainbow(reduceMotion: true));
    await tester.pump();

    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: 'reduce motion 時はアニメを止める',
    );

    // 静止でも虹色は乗る＝テキストは foreground シェーダを持つ。
    final textSpan = _findTextSpan(tester, 'にじ');
    expect(
      textSpan?.style?.foreground,
      isNotNull,
      reason: 'reduce motion でも無彩色テキストに虹色は乗せる（#864 の目的）',
    );
  });
}

/// 描画中の全 [RichText] を横断し、[text] に一致する [TextSpan] を探す。
/// `Text.rich` は渡した span を effectiveTextStyle の TextSpan の下にもう 1 段
/// 入れ子にするため、直下だけ見ると取りこぼす。再帰で辿る。
TextSpan? _findTextSpan(WidgetTester tester, String text) {
  TextSpan? found;
  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    rt.text.visitChildren((span) {
      if (span is TextSpan && span.text == text) {
        found = span;
        return false;
      }
      return true;
    });
    if (found != null) break;
  }
  return found;
}

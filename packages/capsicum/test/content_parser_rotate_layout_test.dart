import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #876: `$[rotate]` の 90° 刻みは `RotatedBox` でレイアウト寸法ごと入れ替える。
///
/// Transform.rotate は塗りだけ回してレイアウトの占有ボックスを変えないため、
/// 縦積みを 90° 倒して横長リールにするスロット系 Play が予約幅を超えて左に
/// 食み出し、左端が見切れていた。90° 刻みなら RotatedBox で横倒し後の幅を確保
/// できるので食み出さない。90° の倍数でない角度は近似できないため Transform.rotate。
void main() {
  ContentRenderer buildRenderer() => ContentRenderer(
    baseStyle: const TextStyle(fontSize: 14),
    resolveEmoji: (_) => null,
  );

  Future<void> pumpMfm(WidgetTester tester, String mfm) async {
    final renderer = buildRenderer();
    addTearDown(renderer.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Text.rich(renderer.renderMfm(mfm)))),
    );
  }

  testWidgets(r'$[rotate ...]（既定 90°）は RotatedBox で quarterTurns=1', (
    tester,
  ) async {
    await pumpMfm(tester, r'$[rotate ABC]');
    final boxes = tester.widgetList<RotatedBox>(find.byType(RotatedBox));
    expect(boxes, isNotEmpty);
    expect(boxes.any((b) => b.quarterTurns == 1), isTrue);
  });

  testWidgets(r'$[rotate.deg=-90 ...] は RotatedBox で quarterTurns=-1', (
    tester,
  ) async {
    await pumpMfm(tester, r'$[rotate.deg=-90 ABC]');
    final boxes = tester.widgetList<RotatedBox>(find.byType(RotatedBox));
    expect(boxes.any((b) => b.quarterTurns == -1), isTrue);
  });

  testWidgets('90° 倒すとレイアウト幅と高さが入れ替わる（食み出さない）', (tester) async {
    // 縦長の子（改行で 3 行）を 90° 倒すと、レイアウト上は横長になる。
    // Transform.rotate 時代は占有ボックスが縦長のままで、横倒しの塗りが
    // 予約幅を超えて食み出していた。RotatedBox 化で幅 > 高さになることを確認する。
    await pumpMfm(tester, '\$[rotate A\nB\nC]');
    final size = tester.getSize(find.byType(RotatedBox).first);
    expect(
      size.width,
      greaterThan(size.height),
      reason: '90° 倒した縦積みはレイアウト上も横長になるべき',
    );
  });

  testWidgets('90° の倍数でない角度は Transform.rotate に退避（RotatedBox を使わない）', (
    tester,
  ) async {
    await pumpMfm(tester, r'$[rotate.deg=45 ABC]');
    expect(find.byType(RotatedBox), findsNothing);
  });
}

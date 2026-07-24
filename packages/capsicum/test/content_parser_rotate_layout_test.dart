import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #876: `$[rotate]` は本家 Misskey (MkMfm.ts) と同じ paint-only の
/// `Transform.rotate` で表現する（レイアウト予約はしない）。
///
/// 一時期 90° 刻みを `RotatedBox` でレイアウト予約して左見切れを防いだが、
/// スロット系 Play は横間隔を `$[position.y]`（paint-only 平行移動）だけで作る
/// 本家前提の合成のため、予約すると予約列と position.y が二重に効いて絵文字が
/// 重なる。予約と paint-only は両立しないので本家に倣い paint-only に統一した。
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

  testWidgets(r'$[rotate ...]（既定 90°）は Transform.rotate（RotatedBox を使わない）', (
    tester,
  ) async {
    await pumpMfm(tester, r'$[rotate ABC]');
    expect(find.byType(RotatedBox), findsNothing);
    expect(find.byType(Transform), findsWidgets);
  });

  testWidgets(r'$[rotate.deg=-90 ...] も Transform.rotate', (tester) async {
    await pumpMfm(tester, r'$[rotate.deg=-90 ABC]');
    expect(find.byType(RotatedBox), findsNothing);
    expect(find.byType(Transform), findsWidgets);
  });

  testWidgets('縦積みを 90° 倒してもレイアウト占有ボックスは入れ替えない（paint-only）', (tester) async {
    // paint-only なので占有ボックスは子（縦積み 3 行）の縦長のまま。
    // RotatedBox 時代のように幅と高さは入れ替わらない。横間隔・見切れは
    // レイアウトではなく position.y の描画ずらし + 非 clip で扱う。
    await pumpMfm(tester, '\$[rotate A\nB\nC]');
    final size = tester.getSize(find.byType(Transform).first);
    expect(
      size.height,
      greaterThan(size.width),
      reason: 'paint-only は占有ボックスを回さないため縦積みは縦長のまま',
    );
  });

  testWidgets('90° の倍数でない角度も Transform.rotate（従来どおり）', (tester) async {
    await pumpMfm(tester, r'$[rotate.deg=45 ABC]');
    expect(find.byType(RotatedBox), findsNothing);
    expect(find.byType(Transform), findsWidgets);
  });
}

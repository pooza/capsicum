import 'dart:typed_data';

import 'package:capsicum/src/model/image_overlay_layer.dart';
import 'package:capsicum/src/ui/util/image_overlay_geometry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/image_editor_harness.dart';

/// #1183: 文字レイヤの行揃えを、左・中央・右から選べるようにする。
///
/// ⚠ **見る側は 2 箇所ある** —— 編集中のプレビューと、書き出し（焼き込み）。
/// 片方だけだと「編集中の見た目と投稿される画像が違う」になる。ここでは
/// プレビューと、画面の外へ出る記述（再編集・下書きの元）が揃うことを固定する。
void main() {
  late Uint8List basePng;

  setUpAll(() async {
    basePng = await solidPng(160, 160, const Color(0xFF0000FF));
  });

  TextAlign? previewAlign(WidgetTester tester, String text) => tester
      .widgetList<Text>(find.text(text))
      .map((t) => t.textAlign)
      .whereType<TextAlign>()
      .firstOrNull;

  testWidgets('前提: 足したばかりの文字レイヤは中央', (tester) async {
    final harness = await ImageEditorHarness.open(tester, imageData: basePng);
    await harness.addText('おはよう');

    expect(previewAlign(tester, 'おはよう'), TextAlign.center);
    await harness.export();
    expect(
      (harness.exportedLayers!.single as TextOverlayLayerSpec).align,
      TextAlign.center,
    );
  });

  testWidgets('ボタンを押すたびに 中央 → 右 → 左 と回り、プレビューと記述に出る', (tester) async {
    final harness = await ImageEditorHarness.open(tester, imageData: basePng);
    await harness.addText('おはよう');

    await tester.tap(find.byKey(overlayTextAlignButtonKey));
    await tester.pumpAndSettle();
    expect(previewAlign(tester, 'おはよう'), TextAlign.right);
    expect(find.byTooltip('行揃え: 右（押すと切り替え）'), findsOneWidget);

    await tester.tap(find.byKey(overlayTextAlignButtonKey));
    await tester.pumpAndSettle();
    expect(previewAlign(tester, 'おはよう'), TextAlign.left);

    await harness.export();
    expect(
      (harness.exportedLayers!.single as TextOverlayLayerSpec).align,
      TextAlign.left,
      reason: '⚠ 記述に出ないと、再編集と下書きで中央へ戻る',
    );
  });

  testWidgets('⚠ 開き直しても行揃えが保たれる（記述 → 画面 → 記述）', (tester) async {
    const spec = TextOverlayLayerSpec(
      text: 'みぎよせ',
      color: Color(0xFFFFFFFF),
      align: TextAlign.right,
      nx: 0.5,
      ny: 0.5,
      sizeFrac: 0.1,
      angle: 0,
      opacity: 1,
      visible: true,
      locked: false,
    );
    final harness = await ImageEditorHarness.open(
      tester,
      imageData: basePng,
      initialLayers: const [spec],
    );
    await harness.settle();

    expect(previewAlign(tester, 'みぎよせ'), TextAlign.right);
    await harness.export();
    expect(
      (harness.exportedLayers!.single as TextOverlayLayerSpec).align,
      TextAlign.right,
    );
  });
}

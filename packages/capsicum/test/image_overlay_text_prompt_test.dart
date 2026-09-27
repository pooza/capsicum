import 'dart:typed_data';

import 'package:capsicum/src/model/image_overlay_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/image_editor_harness.dart';

/// #1126: 文字レイヤの入力欄。
///
/// 字数も改行も元から制限していなかったが、欄が 1 行ぶんしかなく「短い文字しか
/// 入らない」ように見えた。数行ぶんの高さを最初から取り、幅はダイアログが許す
/// 最大（上限 480px）まで広げる。
void main() {
  late Uint8List png;

  setUpAll(() async {
    png = await solidPng(160, 160, const Color(0xFF0000FF));
  });

  Future<void> openPrompt(WidgetTester tester, Size surface) async {
    await ImageEditorHarness.open(tester, imageData: png, surfaceSize: surface);
    await tester.tap(find.text('テキストを追加'));
    await tester.pumpAndSettle();
  }

  Size fieldSize(WidgetTester tester) =>
      tester.getSize(find.byType(TextField).last);

  testWidgets('空のままでも数行ぶんの高さで開く', (tester) async {
    await openPrompt(tester, const Size(800, 1000));

    // 1 行ぶんの欄は 60px 前後。4 行ぶんなら 100px を確実に超える。
    expect(fieldSize(tester).height, greaterThan(100));
  });

  testWidgets('広い画面では幅が 480px で頭打ちになる', (tester) async {
    await openPrompt(tester, const Size(1600, 1000));

    final width = fieldSize(tester).width;
    expect(width, greaterThan(360));
    expect(width, lessThanOrEqualTo(480));
  });

  testWidgets('320px 幅でもダイアログからはみ出さない', (tester) async {
    await openPrompt(tester, const Size(320, 800));

    expect(tester.takeException(), isNull);
    expect(fieldSize(tester).width, lessThan(320));
  });

  testWidgets('改行を含む文字がそのままレイヤになる', (tester) async {
    final harness = await ImageEditorHarness.open(tester, imageData: png);
    await harness.addText('1 行目\n2 行目');
    await harness.export();

    final layer = harness.exportedLayers!.single as TextOverlayLayerSpec;
    expect(layer.text, '1 行目\n2 行目');
  });
}

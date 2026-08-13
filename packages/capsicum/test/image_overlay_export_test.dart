import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/image_editor_harness.dart';

/// 画像編集フローを画面操作から書き出しまで通し、**合成結果をピクセルで**確かめる
/// (#947)。
///
/// #883（添付画像スタンプ）の確認が人手に落ちたのは、まさにこの層に自動の網が
/// 無かったため。ジオメトリ計算は `image_overlay_geometry_test`、狭幅のレイアウトは
/// `image_overlay_add_row_test` が既に押さえているので、ここは「操作した結果が実際に
/// 画へ出るか」だけを見る。
///
/// 土台と `runAsync` の作法は [ImageEditorHarness] 側に閉じ込めてある。
void main() {
  const base = Color(0xFF0000FF); // 元画像（青）
  const sticker = Color(0xFF00FF00); // スタンプ素材（緑）

  final emoji = CustomEmoji(
    shortcode: 'gomechan',
    url: 'https://example.invalid/gomechan.png',
    category: 'ゴメちゃん',
    aliases: const [],
  );

  // 素材は実時間ゾーンで用意する。`testWidgets` の中は擬似非同期で `toImage` が
  // 完了せず、黙ってハングする（[solidPng] の注意書き参照）。
  late Uint8List basePng120;
  late Uint8List basePng160;
  late ui.Image stickerMaster;

  setUpAll(() async {
    basePng120 = await solidPng(120, 120, base);
    basePng160 = await solidPng(160, 160, base);
    stickerMaster = await solidImage(40, 40, sticker);
  });

  tearDownAll(() => stickerMaster.dispose());

  // 画面側が dispose するので、毎回 clone を渡す。
  FakeStickerSource fakeSource() =>
      FakeStickerSource(emoji: emoji, imageBuilder: stickerMaster.clone);

  group('画像オーバーレイの書き出し (#947)', () {
    testWidgets('何も足さずに書き出すと元画像のまま', (tester) async {
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng120,
      );

      final png = await harness.exportDecoded();

      expect(png.width, 120);
      expect(png.height, 120);
      expect(png.at(60, 60), base);
      expect(png.countNear(sticker), 0);
    });

    testWidgets('スタンプを載せて書き出すと素材の色が画に出る', (tester) async {
      final source = fakeSource();
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng120,
        stickerSource: source,
      );

      await harness.addSticker();
      final png = await harness.exportDecoded();

      expect(source.loadCount, 1, reason: '素材の取得は 1 回だけ');
      expect(png.countNear(sticker), greaterThan(0), reason: 'スタンプが合成されていない');
      // 端は元画像のまま（スタンプは中央に既定サイズで載る）。
      expect(png.at(2, 2), base);
    });

    testWidgets('スライダーで大きくすると、その分だけ画の占有面積が増える', (tester) async {
      Future<int> stickerPixelsAt(double size) async {
        final harness = await ImageEditorHarness.open(
          tester,
          imageData: basePng160,
          stickerSource: fakeSource(),
        );
        await harness.addSticker();
        await harness.setSize(size);
        final png = await harness.exportDecoded();
        return png.countNear(sticker);
      }

      final small = await stickerPixelsAt(0.1);
      final large = await stickerPixelsAt(0.9);

      expect(small, greaterThan(0));
      expect(large, greaterThan(small), reason: 'スライダーを上げても書き出しに反映されていない');
    });

    testWidgets('ピッカーをキャンセルすると何も載らない', (tester) async {
      final source = FakeStickerSource(
        emoji: null,
        imageBuilder: stickerMaster.clone,
      );
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng120,
        stickerSource: source,
      );

      await harness.addSticker();
      final png = await harness.exportDecoded();

      expect(source.loadCount, 0, reason: '選んでいないのに取得しに行っている');
      expect(png.countNear(sticker), 0);
    });

    // #947 の土台が最初に見つけた不具合の回帰テスト。ダイアログの
    // TextEditingController を `showDialog` 解決直後に dispose していたため、
    // まだ退場アニメーション中の TextField が再構築されて use-after-dispose に
    // なっていた（debug では assertion、release では黙って通る）。
    testWidgets('テキスト入力ダイアログを閉じても controller の後始末で落ちない', (tester) async {
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng120,
      );

      await harness.addText('ゴメ');
      // 退場アニメーションが終わるまで進める。ここで再構築が走る。
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.takeException(), isNull);
    });

    testWidgets('テキストを載せて書き出すと元画像に別色が乗る', (tester) async {
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng160,
      );

      await harness.addText('ゴメ');
      final png = await harness.exportDecoded();

      // 既定の文字色は白。元画像が単色青なので、白が出ていれば文字が焼けている。
      expect(
        png.countNear(const Color(0xFFFFFFFF)),
        greaterThan(0),
        reason: 'テキストが合成されていない',
      );
    });
  });
}

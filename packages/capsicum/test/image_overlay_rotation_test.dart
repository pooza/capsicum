import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum/src/ui/util/image_overlay_geometry.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/image_editor_harness.dart';

/// #946: レイヤの回転を、書き出した画のピクセルで確かめる。
///
/// **回転はこのエディタでいちばん WYSIWYG が壊れやすい変更**。位置・大きさと
/// 違って「回す中心」という自由度があり、編集画面（[Transform.rotate] は中心
/// まわり）と書き出し（Canvas は原点まわり）で既定が食い違うためで、揃え損ねると
/// 角度を動かした瞬間にレイヤが飛ぶ。
///
/// 正方形の素材だと回しても見た目が変わらず素通しになるので、**横長（4:1）の
/// 素材**を使い、回転で占有する向きが変わることを見る。
void main() {
  const base = Color(0xFF0000FF); // 元画像（青）
  const sticker = Color(0xFF00FF00); // スタンプ素材（緑）

  final emoji = CustomEmoji(
    shortcode: 'wide',
    url: 'https://example.invalid/wide.png',
    category: null,
    aliases: const [],
  );

  late Uint8List basePng;
  late ui.Image wideSticker;

  setUpAll(() async {
    basePng = await solidPng(160, 160, base);
    // 4:1 の横長。既定 sizeFrac 0.2 × 基準高 160 = 高さ 32 / 幅 128 になる。
    wideSticker = await solidImage(80, 20, sticker);
  });

  tearDownAll(() => wideSticker.dispose());

  FakeStickerSource fakeSource() =>
      FakeStickerSource(emoji: emoji, imageBuilder: wideSticker.clone);

  Future<ImageEditorHarness> openWithSticker(WidgetTester tester) async {
    final harness = await ImageEditorHarness.open(
      tester,
      imageData: basePng,
      stickerSource: fakeSource(),
    );
    await harness.addSticker();
    return harness;
  }

  group('書き出しへの反映 (#946)', () {
    // 既定（無回転）。高さ 32 / 幅 128 が中心 (80,80) に載るので、
    // 横方向へは端近くまで届き、縦方向は 64..96 に収まる。
    testWidgets('回さなければ横長のまま載る', (tester) async {
      final harness = await openWithSticker(tester);

      final png = await harness.exportDecoded();

      expect(png.at(140, 80), sticker, reason: '横方向に伸びていない');
      expect(png.at(80, 40), base, reason: '縦方向へはみ出している');
    });

    testWidgets('90 度回すと縦長になる（向きが入れ替わる）', (tester) async {
      final harness = await openWithSticker(tester);
      await harness.setAngleDegrees(90);

      final png = await harness.exportDecoded();

      expect(png.at(80, 40), sticker, reason: '回転が書き出しに効いていない');
      expect(png.at(140, 80), base, reason: '回す前の向きのまま残っている');
    });

    /// ⚠ **これが「回す中心」の検査**。左上まわりに回すとレイヤが画像の外へ
    /// 出ていき、占有面積が激減する（あるいは 0 になる）。
    testWidgets('回しても占有面積はほぼ変わらない（中心まわりに回っている）', (tester) async {
      Future<int> pixelsAt(double degrees) async {
        final harness = await openWithSticker(tester);
        if (degrees != 0) await harness.setAngleDegrees(degrees);
        final png = await harness.exportDecoded();
        return png.countNear(sticker);
      }

      final flat = await pixelsAt(0);
      final turned = await pixelsAt(90);

      expect(flat, greaterThan(0));
      // 同じ形を回しただけなので面積は保存される。縁のアンチエイリアスぶんを
      // 見込んで 5% の幅を許す。
      expect(turned, closeTo(flat, flat * 0.05));
    });

    testWidgets('中途半端な角度でも載る（吸着していない）', (tester) async {
      final harness = await openWithSticker(tester);
      await harness.setAngleDegrees(20);

      final png = await harness.exportDecoded();

      // 20 度なら、無回転では元画像だった斜め上の位置に掛かる。
      expect(png.countNear(sticker), greaterThan(0));
      expect(png.at(140, 80), base, reason: '傾いていない（0 度に吸着している）');
    });

    testWidgets('リセットすると無回転の見た目に戻る', (tester) async {
      final harness = await openWithSticker(tester);
      await harness.setAngleDegrees(90);
      await harness.resetAngle();

      final png = await harness.exportDecoded();

      expect(png.at(140, 80), sticker);
      expect(png.at(80, 40), base);
    });

    /// #946 の眼目は「テキストとスタンプの**両方**に入れて初めて筋が通る」こと。
    /// 片方だけだと同じキャンバス上で操作体系が食い違う。
    testWidgets('テキストレイヤも回る', (tester) async {
      Future<int> whitePixels(double degrees) async {
        final harness = await ImageEditorHarness.open(
          tester,
          imageData: basePng,
        );
        await harness.addText('ゴメ');
        if (degrees != 0) await harness.setAngleDegrees(degrees);
        final png = await harness.exportDecoded();
        return png.countNear(const Color(0xFFFFFFFF));
      }

      final flat = await whitePixels(0);
      final turned = await whitePixels(90);

      expect(flat, greaterThan(0), reason: 'テキストが載っていない');
      expect(turned, greaterThan(0), reason: '回すとテキストが消えている');
    });
  });

  group('overlayAngleLabel', () {
    test('ラジアンを度数で表示する', () {
      expect(overlayAngleLabel(0), '0°');
      expect(overlayAngleLabel(kOverlayMaxAngle), '180°');
      expect(overlayAngleLabel(kOverlayMinAngle), '-180°');
      expect(overlayAngleLabel(kOverlayMaxAngle / 2), '90°');
    });

    test('端数は丸める（1 度未満は見せない）', () {
      expect(overlayAngleLabel(kOverlayMaxAngle / 180 * 12.4), '12°');
      expect(overlayAngleLabel(kOverlayMaxAngle / 180 * 12.6), '13°');
    });
  });

  group('スライダの範囲', () {
    /// 中央が正確に 0 になること。吸着を入れない代わりに、**中央＝無回転**を
    /// 範囲の対称性で担保している（[kOverlayMaxAngle] の doc）。
    test('中央が無回転になるよう対称', () {
      expect(kOverlayMinAngle, -kOverlayMaxAngle);
      expect((kOverlayMinAngle + kOverlayMaxAngle) / 2, 0);
    });
  });
}

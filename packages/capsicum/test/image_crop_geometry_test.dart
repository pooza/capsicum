import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum/src/model/image_overlay_layer.dart';
import 'package:capsicum/src/ui/util/image_crop_geometry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1132: レイヤを載せた画像をトリミング / 回転しても、レイヤが同じ見え方の位置に
/// 残る。
///
/// ⚠ 期待値は**画像の上の実寸（px）**で確かめる。レイヤは正規化座標と比率で
/// 持つので、切る前と切ったあとで「画像のどの画素の上に・何 px の大きさで」
/// 載っているかが変わらなければ、見え方は変わっていない。
void main() {
  StickerOverlayLayerSpec sticker({
    double nx = 0.5,
    double ny = 0.5,
    double sizeFrac = 0.2,
    double angle = 0,
  }) => StickerOverlayLayerSpec(
    shortcode: 's',
    url: 'https://example.invalid/s.png',
    nx: nx,
    ny: ny,
    sizeFrac: sizeFrac,
    angle: angle,
    opacity: 0.6,
    visible: false,
    locked: true,
  );

  OverlayLayerSpec remap(OverlayLayerSpec layer, ImageCropGeometry geometry) =>
      remapLayersForCrop([layer], geometry).single;

  group('切り出しだけ（回さない）', () {
    // 元画像は 400×200。右半分（x: 200..400）を切り出す。
    const geometry = ImageCropGeometry(
      quarterTurns: 0,
      rotatedSize: Size(400, 200),
      cropRect: Rect.fromLTWH(200, 0, 200, 200),
    );

    test('切った範囲の中のレイヤは、同じ画素の上に残る', () {
      // 元画像の (300, 100) ＝ 切った範囲の中央。
      final moved = remap(sticker(nx: 0.75, ny: 0.5), geometry);
      expect(moved.nx, closeTo(0.5, 1e-9));
      expect(moved.ny, closeTo(0.5, 1e-9));
    });

    test('高さが変わらなければ、大きさの比率も変わらない', () {
      expect(remap(sticker(sizeFrac: 0.2), geometry).sizeFrac, 0.2);
    });

    test('⚠ 高さを半分に切ったら、比率は 2 倍（実寸は同じ）', () {
      const half = ImageCropGeometry(
        quarterTurns: 0,
        rotatedSize: Size(400, 200),
        cropRect: Rect.fromLTWH(0, 50, 400, 100),
      );
      final moved = remap(sticker(sizeFrac: 0.2, ny: 0.5), half);
      expect(moved.sizeFrac, closeTo(0.4, 1e-9));
      expect(moved.sizeFrac * 100, closeTo(0.2 * 200, 1e-9), reason: '実寸 40px');
      expect(moved.ny, closeTo(0.5, 1e-9));
    });

    test('⚠⚠ 枠の外へ出たレイヤも捨てない（座標が 0..1 の外になるだけ）', () {
      // 元画像の (100, 100) ＝ 切り落とした左半分。
      final layers = remapLayersForCrop([
        sticker(nx: 0.25),
        sticker(nx: 0.75),
      ], geometry);
      expect(layers, hasLength(2), reason: '⚠ 少し切り詰めただけでスタンプが消えない');
      expect(layers.first.nx, closeTo(-0.5, 1e-9));
    });
  });

  group('回すだけ（切らない）', () {
    // 元画像は 400×200。時計回りに 1 回 → 200×400。
    const cw = ImageCropGeometry(
      quarterTurns: 1,
      rotatedSize: Size(200, 400),
      cropRect: Rect.fromLTWH(0, 0, 200, 400),
    );

    test('時計回り 1 回: 左上のレイヤは右上へ行く', () {
      // 元画像の左上寄り (40, 20) → 回したあとは (200 - 20, 40) = (180, 40)。
      final moved = remap(sticker(nx: 0.1, ny: 0.1), cw);
      expect(moved.nx * 200, closeTo(180, 1e-9));
      expect(moved.ny * 400, closeTo(40, 1e-9));
    });

    test('⚠ 大きさの実寸は変わらない（基準の高さが、元の幅になる）', () {
      final moved = remap(sticker(sizeFrac: 0.2), cw);
      expect(moved.sizeFrac * 400, closeTo(0.2 * 200, 1e-9));
    });

    test('角度も一緒に回る', () {
      expect(remap(sticker(angle: 0), cw).angle, closeTo(math.pi / 2, 1e-9));
    });

    test('⚠ 角度は編集画面のスライダの範囲（-π〜π）へ収める', () {
      final moved = remap(sticker(angle: math.pi * 0.75), cw);
      expect(moved.angle, closeTo(-math.pi * 0.75, 1e-9));
      expect(moved.angle.abs(), lessThanOrEqualTo(math.pi));
    });

    test('⚠⚠ 4 回回したら、元へ戻る', () {
      var layer =
          sticker(nx: 0.2, ny: 0.7, sizeFrac: 0.15, angle: 0.3)
              as OverlayLayerSpec;
      var size = const Size(400, 200);
      for (var i = 0; i < 4; i++) {
        size = Size(size.height, size.width);
        layer = remap(
          layer,
          ImageCropGeometry(
            quarterTurns: 1,
            rotatedSize: size,
            cropRect: Offset.zero & size,
          ),
        );
      }
      expect(layer.nx, closeTo(0.2, 1e-9));
      expect(layer.ny, closeTo(0.7, 1e-9));
      expect(layer.sizeFrac, closeTo(0.15, 1e-9));
      expect(layer.angle, closeTo(0.3, 1e-9));
    });

    test('3 回まとめて回すのと、1 回ずつ 3 回は同じ', () {
      final once = remap(
        sticker(nx: 0.2, ny: 0.7),
        const ImageCropGeometry(
          quarterTurns: 3,
          rotatedSize: Size(200, 400),
          cropRect: Rect.fromLTWH(0, 0, 200, 400),
        ),
      );
      // 反時計回り 1 回 ＝ (x, y) → (y, W - x)。元画像の (80, 140) → (140, 320)。
      expect(once.nx * 200, closeTo(140, 1e-9));
      expect(once.ny * 400, closeTo(320, 1e-9));
    });
  });

  group('回してから切る', () {
    test('回したあとの座標で切る', () {
      // 400×200 を時計回りに 1 回 → 200×400。その下半分（y: 200..400）を切る。
      const geometry = ImageCropGeometry(
        quarterTurns: 1,
        rotatedSize: Size(200, 400),
        cropRect: Rect.fromLTWH(0, 200, 200, 200),
      );
      // 元画像の (300, 100) → 回したあと (100, 300) → 切ったあと (100, 100)。
      final moved = remap(sticker(nx: 0.75, ny: 0.5, sizeFrac: 0.2), geometry);
      expect(moved.nx * 200, closeTo(100, 1e-9));
      expect(moved.ny * 200, closeTo(100, 1e-9));
      expect(moved.sizeFrac * 200, closeTo(0.2 * 200, 1e-9), reason: '実寸 40px');
    });
  });

  group('置き場所のほかは変えない', () {
    const geometry = ImageCropGeometry(
      quarterTurns: 1,
      rotatedSize: Size(200, 400),
      cropRect: Rect.fromLTWH(10, 20, 100, 200),
    );
    const placement = {'nx', 'ny', 'sizeFrac', 'angle'};

    // ⚠⚠ 記述を作り直すので、項目を足したときに写し忘れると、**トリミングした
    // だけでその項目が既定値へ戻る**。JSON に出る項目で機械的に見る。
    for (final layer in <OverlayLayerSpec>[
      const TextOverlayLayerSpec(
        text: 'もじ',
        color: Color(0xFF123456),
        align: TextAlign.right,
        nx: 0.3,
        ny: 0.4,
        sizeFrac: 0.1,
        angle: 0.2,
        opacity: 0.5,
        visible: false,
        locked: true,
      ),
      sticker(),
      const PictureOverlayLayerSpec(
        path: '/tmp/p.png',
        name: 'p.png',
        nx: 0.3,
        ny: 0.4,
        sizeFrac: 0.1,
        angle: 0.2,
        opacity: 0.5,
        visible: false,
        locked: true,
      ),
    ]) {
      test('${layer.runtimeType}', () {
        final before = layer.toJson();
        final after = remap(layer, geometry).toJson();
        expect(after.keys.toSet(), before.keys.toSet());
        for (final key in before.keys.where((k) => !placement.contains(k))) {
          expect(after[key], before[key], reason: '$key が変わった');
        }
        expect(after['nx'], isNot(before['nx']), reason: '前提: 置き場所は変わる');
      });
    }
  });

  test('切り方が空（大きさ 0）なら、何もしない', () {
    final layers = [sticker()];
    expect(
      remapLayersForCrop(
        layers,
        const ImageCropGeometry(
          quarterTurns: 0,
          rotatedSize: Size.zero,
          cropRect: Rect.zero,
        ),
      ),
      same(layers),
    );
  });

  test('回した回数は 0〜3 に収まる', () {
    expect(ImageCropGeometry.turned(0, clockwise: true), 1);
    expect(ImageCropGeometry.turned(3, clockwise: true), 0);
    expect(ImageCropGeometry.turned(0, clockwise: false), 3);
    expect(ImageCropGeometry.turned(1, clockwise: false), 0);
  });

  // 焼き込み前の画像にも、同じ切り方を当てる。4 隅に色を置いた画像で、
  // 「どの画素がどこへ行ったか」を見る。
  group('applyCropGeometry', () {
    late Uint8List png;
    const red = Color(0xFFFF0000); // 左上
    const green = Color(0xFF00FF00); // 右上
    const blue = Color(0xFF0000FF); // 左下
    const white = Color(0xFFFFFFFF); // 右下

    setUpAll(() async {
      // 40×20。左右・上下の 4 区画に色を置く。
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      void fill(Rect rect, Color color) =>
          canvas.drawRect(rect, Paint()..color = color);
      fill(const Rect.fromLTWH(0, 0, 20, 10), red);
      fill(const Rect.fromLTWH(20, 0, 20, 10), green);
      fill(const Rect.fromLTWH(0, 10, 20, 10), blue);
      fill(const Rect.fromLTWH(20, 10, 20, 10), white);
      final picture = recorder.endRecording();
      final image = await picture.toImage(40, 20);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      png = data!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
    });

    Future<({int width, int height, Color Function(int x, int y) at})> decode(
      Uint8List bytes,
    ) async {
      final codec = await ui.instantiateImageCodec(bytes);
      final image = (await codec.getNextFrame()).image;
      final data = (await image.toByteData())!;
      final width = image.width;
      final height = image.height;
      image.dispose();
      codec.dispose();
      Color at(int x, int y) {
        final i = (y * width + x) * 4;
        return Color.fromARGB(
          data.getUint8(i + 3),
          data.getUint8(i),
          data.getUint8(i + 1),
          data.getUint8(i + 2),
        );
      }

      return (width: width, height: height, at: at);
    }

    test('切り出しだけ: 右半分', () async {
      final out = await decode(
        await applyCropGeometry(
          png,
          const ImageCropGeometry(
            quarterTurns: 0,
            rotatedSize: Size(40, 20),
            cropRect: Rect.fromLTWH(20, 0, 20, 20),
          ),
        ),
      );
      expect((out.width, out.height), (20, 20));
      expect(out.at(5, 5), green);
      expect(out.at(5, 15), white);
    });

    test('⚠ 時計回り 1 回: 左上が右上へ行く（トリミング画面と同じ向き）', () async {
      final out = await decode(
        await applyCropGeometry(
          png,
          const ImageCropGeometry(
            quarterTurns: 1,
            rotatedSize: Size(20, 40),
            cropRect: Rect.fromLTWH(0, 0, 20, 40),
          ),
        ),
      );
      expect((out.width, out.height), (20, 40));
      expect(out.at(15, 5), red, reason: '左上 → 右上');
      expect(out.at(15, 35), green, reason: '右上 → 右下');
      expect(out.at(5, 5), blue, reason: '左下 → 左上');
      expect(out.at(5, 35), white, reason: '右下 → 左下');
    });

    test('反時計回り 1 回（＝ 3 回）: 左上が左下へ行く', () async {
      final out = await decode(
        await applyCropGeometry(
          png,
          const ImageCropGeometry(
            quarterTurns: 3,
            rotatedSize: Size(20, 40),
            cropRect: Rect.fromLTWH(0, 0, 20, 40),
          ),
        ),
      );
      expect(out.at(5, 35), red);
      expect(out.at(5, 5), green);
    });

    test('2 回: 上下左右が入れ替わる', () async {
      final out = await decode(
        await applyCropGeometry(
          png,
          const ImageCropGeometry(
            quarterTurns: 2,
            rotatedSize: Size(40, 20),
            cropRect: Rect.fromLTWH(0, 0, 40, 20),
          ),
        ),
      );
      expect(out.at(35, 15), red);
      expect(out.at(5, 5), white);
    });

    test('⚠ 大きさが違う画像にも、割合で同じ範囲を当てる', () async {
      // 切り方は 80×40 の画像に対して測ったもの（＝ 2 倍の大きさ）。
      final out = await decode(
        await applyCropGeometry(
          png,
          const ImageCropGeometry(
            quarterTurns: 0,
            rotatedSize: Size(80, 40),
            cropRect: Rect.fromLTWH(40, 20, 40, 20),
          ),
        ),
      );
      expect((out.width, out.height), (20, 10));
      expect(out.at(10, 5), white, reason: '右下の区画');
    });
  });
}

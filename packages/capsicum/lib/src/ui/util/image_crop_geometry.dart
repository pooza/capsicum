/// トリミング / 回転の「切り方」と、それをレイヤと元画像へ当てる計算 (#1132)。
///
/// トリミング画面（`ImageCropScreen`）とレイヤの編集画面（`ImageOverlayScreen`）は
/// 独立したままで、どちらも PNG を返すだけだった。なので、レイヤを載せた画像を
/// トリミングすると**平らな画像に戻り、レイヤの控えを捨てるしかなかった**。
///
/// ここでは、トリミング画面が返す「何回回して、どこを切ったか」（[ImageCropGeometry]）
/// を使って:
///
/// - レイヤの座標を、切ったあとの画像の座標へ移す（[remapLayersForCrop]）
/// - 焼き込み**前**の画像にも、同じ切り方を当てる（[applyCropGeometry]）
///
/// こうすると「焼き込み済み・焼き込み前・レイヤ列」の 3 つが切ったあとも対のまま
/// 残り、あとからレイヤを編集し直せる。
///
/// ⚠ **2 画面は統合していない**（#1131 の決定）。トリミング中に見えているのは
/// 焼き込み済みの画像で、レイヤは絵の一部として一緒に切られる。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../model/image_overlay_layer.dart';

/// トリミング画面での切り方。
class ImageCropGeometry {
  const ImageCropGeometry({
    required this.quarterTurns,
    required this.rotatedSize,
    required this.cropRect,
  });

  /// 時計回りに 90° 回した回数（0〜3）。
  final int quarterTurns;

  /// 回したあと・切る前の画像の大きさ（px）。
  final Size rotatedSize;

  /// [rotatedSize] の中の、切り出した範囲（px）。
  final Rect cropRect;

  /// 時計回りに 1 回（[clockwise] が false なら反時計回りに 1 回）回したあとの
  /// 回数。常に 0〜3 に収める。
  static int turned(int quarterTurns, {required bool clockwise}) =>
      (quarterTurns + (clockwise ? 1 : 3)) % 4;
}

/// [layers] を、[geometry] で切ったあとの画像の座標へ移す。
///
/// レイヤは位置を正規化座標 (0..1)、大きさを画像の高さに対する比率で持つので、
/// 「基準になる画像」が変わったぶんを換算するだけで、**見え方の位置と大きさは
/// 変わらない**。
///
/// - 90° 時計回り 1 回: `(nx, ny) → (1 - ny, nx)`・角度に +90°・大きさは
///   「元の高さ」基準から「元の幅」基準へ
/// - 切り出し: 切った範囲の左上を原点に取り直し、大きさは切ったあとの高さ基準へ
///
/// ⚠⚠ **枠の外へ出たレイヤも捨てない。**座標が 0..1 の外になるだけで、記述は
/// 残す。見えなくなるが、編集画面の一覧から選んで動かせば戻る（動かした時点で
/// 画像の内側へ寄る）。捨てると「少し切り詰めただけでスタンプが消えた」になる。
///
/// ⚠ **文字の折り返しは保証しない。**折り返し幅は画像の幅で決まるので、幅を
/// 大きく切り詰めた長い文字は、編集し直したときに改行位置が変わりうる
/// （焼き込み済みの画像は変わらない。変わるのは編集画面を開き直したあと）。
List<OverlayLayerSpec> remapLayersForCrop(
  List<OverlayLayerSpec> layers,
  ImageCropGeometry geometry,
) {
  final turns = geometry.quarterTurns % 4;
  final rotated = geometry.rotatedSize;
  final crop = geometry.cropRect;
  if (rotated.isEmpty || crop.isEmpty) return layers;
  // 回す前の大きさ。奇数回なら幅と高さが入れ替わっている。
  var width = turns.isOdd ? rotated.height : rotated.width;
  var height = turns.isOdd ? rotated.width : rotated.height;

  return [
    for (final layer in layers)
      () {
        var nx = layer.nx;
        var ny = layer.ny;
        var sizeFrac = layer.sizeFrac;
        var angle = layer.angle;
        var w = width;
        var h = height;
        for (var i = 0; i < turns; i++) {
          final rotatedNx = 1 - ny;
          ny = nx;
          nx = rotatedNx;
          // 大きさの実寸（sizeFrac × 高さ）は変わらない。基準の高さが、元の幅になる。
          sizeFrac = sizeFrac * h / w;
          angle += math.pi / 2;
          final swapped = w;
          w = h;
          h = swapped;
        }
        // ここで (w, h) は回したあとの大きさ ＝ rotatedSize。
        nx = (nx * w - crop.left) / crop.width;
        ny = (ny * h - crop.top) / crop.height;
        sizeFrac = sizeFrac * h / crop.height;
        return layer.withPlacement(
          nx: nx,
          ny: ny,
          sizeFrac: sizeFrac,
          angle: _normalizeAngle(angle),
        );
      }(),
  ];
}

/// 角度を (-π, π] に収める。編集画面の角度のスライダがこの範囲なので。
double _normalizeAngle(double angle) {
  var a = angle % (2 * math.pi);
  if (a > math.pi) a -= 2 * math.pi;
  if (a <= -math.pi) a += 2 * math.pi;
  return a;
}

/// [bytes] の画像に、[geometry] と同じ切り方を当てて PNG で返す。
///
/// 焼き込み**前**の画像に使う。⚠ 焼き込み済みの画像と大きさが違っていても合う
/// よう、切り出す範囲は [ImageCropGeometry.rotatedSize] に対する割合で当てる。
Future<Uint8List> applyCropGeometry(
  Uint8List bytes,
  ImageCropGeometry geometry,
) async {
  final codec = await ui.instantiateImageCodec(bytes);
  ui.Image? source;
  ui.Picture? picture;
  ui.Image? output;
  try {
    source = (await codec.getNextFrame()).image;
    final turns = geometry.quarterTurns % 4;
    final w = source.width.toDouble();
    final h = source.height.toDouble();
    final rotatedW = turns.isOdd ? h : w;
    final rotatedH = turns.isOdd ? w : h;
    final scaleX = rotatedW / geometry.rotatedSize.width;
    final scaleY = rotatedH / geometry.rotatedSize.height;
    final crop = Rect.fromLTWH(
      geometry.cropRect.left * scaleX,
      geometry.cropRect.top * scaleY,
      geometry.cropRect.width * scaleX,
      geometry.cropRect.height * scaleY,
    );
    final outW = math.max(1, crop.width.round());
    final outH = math.max(1, crop.height.round());

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..translate(-crop.left, -crop.top);
    // ⚠ トリミング画面の回し方（`ImageCropScreen._rotate`）と同じ変換にする。
    switch (turns) {
      case 1:
        canvas
          ..translate(h, 0)
          ..rotate(math.pi / 2);
      case 2:
        canvas
          ..translate(w, h)
          ..rotate(math.pi);
      case 3:
        canvas
          ..translate(0, w)
          ..rotate(-math.pi / 2);
    }
    canvas.drawImage(source, Offset.zero, Paint());
    picture = recorder.endRecording();
    output = await picture.toImage(outW, outH);
    final data = await output.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('Failed to encode cropped PNG');
    return data.buffer.asUint8List();
  } finally {
    source?.dispose();
    picture?.dispose();
    output?.dispose();
    codec.dispose();
  }
}

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum/src/model/image_overlay_layer.dart';
import 'package:capsicum/src/service/sticker_source.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/image_editor_harness.dart';

/// 書き出しの画素を固定する golden (#1125 / #1126 の後継)。
///
/// ## なぜ作り直したか
///
/// 以前の固定値は `image_overlay_layer_id_test` の中にあり、**画面を操作して作った
/// 状態**（テキストを足す → スタンプを足す → ドラッグで端へ寄せる → 選び直す）を
/// 書き出していた。これは**編集画面のレイアウトに依存する** —— #1128 で
/// ツールバーに不透明度の行を 1 本足しただけでキャンバスが 756px から 708px へ
/// 縮み、ドラッグの着地が変わって**描画を何も変えていないのに CI が落ちた**。
///
/// ここでは #1129 の `initialLayers` で**座標も大きさも直接与える**。入力手順にも
/// レイアウトにも依存しないので、動いたら本当に描画が変わっている。
///
/// ## ⚠⚠ 場面は「中間色が 1 画素も出ない」形に限る
///
/// 回転を入れると縁にアンチエイリアスが乗り、その被覆率が macOS と Linux で
/// 一致しない（2026-09-23 実測。30° で 239 画素が中間色になった）。文字の擬似
/// アウトラインも `blurRadius: 0` で sigma 0.5 のぼかしが掛かるので同じ問題を持つ。
///
/// **だから場面は「軸に平行なスタンプだけ」にしてある。**そのうえで
/// [_hasOnlyPureColors] で**中間色が 0 画素であること自体を検査している** ——
/// 将来この場面に回転や文字を足すと、固定値が静かに環境依存になるのではなく、
/// その場で落ちる。
///
/// ⚠ 文字と回転の描画は、画素ではなく**関係式**で押さえてある
/// （`image_overlay_layer_opacity_test` の「全画素で中間になっている」）。
void main() {
  const base = Color(0xFF0000FF);
  const green = Color(0xFF00FF00);
  const red = Color(0xFFFF0000);

  const greenUrl = 'https://example.invalid/green.png';
  const redUrl = 'https://example.invalid/red.png';

  late Uint8List basePng;
  late ui.Image greenMaster;
  late ui.Image redMaster;

  setUpAll(() async {
    basePng = await solidPng(160, 160, base);
    greenMaster = await solidImage(40, 20, green);
    redMaster = await solidImage(40, 20, red);
  });

  tearDownAll(() {
    greenMaster.dispose();
    redMaster.dispose();
  });

  /// 座標も大きさも直接与えた場面。
  ///
  /// ⚠ **整数の矩形になる値を選んである。**`sizeFrac × 160` と、そこから求まる幅が
  /// 整数にならないと縁に中間色が出て、固定値が環境依存になる。
  /// - 緑: 高さ `0.25 × 160 = 40`、幅 `40 × 2 = 80`、中心 (48, 48) → (8,28)-(88,68)
  /// - 赤: 高さ `0.15 × 160 = 24`、幅 `24 × 2 = 48`、中心 (96, 104) → (72,92)-(120,116)
  const scene = <OverlayLayerSpec>[
    StickerOverlayLayerSpec(
      shortcode: 'green',
      url: greenUrl,
      nx: 0.3,
      ny: 0.3,
      sizeFrac: 0.25,
      angle: 0,
      opacity: 1,
      visible: true,
      locked: false,
    ),
    StickerOverlayLayerSpec(
      shortcode: 'red',
      url: redUrl,
      nx: 0.6,
      ny: 0.65,
      sizeFrac: 0.15,
      angle: 0,
      opacity: 1,
      visible: true,
      locked: false,
    ),
  ];

  Future<DecodedPng> exportScene(
    WidgetTester tester, {
    List<OverlayLayerSpec> layers = scene,
    Size surfaceSize = const Size(800, 1000),
  }) async {
    final harness = await ImageEditorHarness.open(
      tester,
      imageData: basePng,
      stickerSource: _ByUrlStickerSource({
        greenUrl: greenMaster.clone,
        redUrl: redMaster.clone,
      }),
      initialLayers: layers,
      surfaceSize: surfaceSize,
    );
    return harness.exportDecoded();
  }

  testWidgets('固定の場面を書き出した画素が変わっていない', (tester) async {
    final png = await exportScene(tester);
    expect(png.width, 160);
    expect(png.height, 160);
    expect(
      _hasOnlyPureColors(png, const [base, green, red]),
      isTrue,
      reason:
          '⚠⚠ 中間色が出た。回転や文字を足すと縁のアンチエイリアスが乗り、'
          '被覆率がプラットフォームで一致しなくなるので、この固定値は環境依存になる',
    );
    expect(png.fingerprint, _expectedFingerprint);
  });

  // ⚠ **固定値が場面の中身を本当に見ていることを確かめる。**書き出しが元画像を
  // 素通しするだけでも「変わっていない」は緑になりうるので、場面を 1 つ変えたら
  // 値が動くことまで見る。
  testWidgets('場面を 1 つ変えると固定値は動く', (tester) async {
    final moved = <OverlayLayerSpec>[
      scene[0],
      StickerOverlayLayerSpec(
        shortcode: 'red',
        url: redUrl,
        nx: 0.55,
        ny: 0.65,
        sizeFrac: 0.15,
        angle: 0,
        opacity: 1,
        visible: true,
        locked: false,
      ),
    ];
    final png = await exportScene(tester, layers: moved);
    expect(png.fingerprint, isNot(_expectedFingerprint));
  });

  // ⚠⚠ **これが #1128 で落とし穴になった軸。**書き出しは原寸の Canvas に対して
  // 行うので、編集画面の大きさには依存しないはず。依存していたら、ツールバーに
  // 行を 1 本足すだけで投稿される画が変わることになる。
  testWidgets('編集画面の大きさを変えても書き出しは 1px も変わらない', (tester) async {
    final wide = await exportScene(tester);
    final narrow = await exportScene(tester, surfaceSize: const Size(320, 640));
    expect(narrow.fingerprint, wide.fingerprint);
  });
}

/// 2026-09-23 に macOS で取得。⚠ **中間色が 0 画素の場面なので、Linux の CI でも
/// 同じ値になる**（回転や文字を足すと成り立たなくなる。上の検査を参照）。
const _expectedFingerprint = 3045787461;

/// 画素が [palette] のどれかに完全一致するか。
///
/// アンチエイリアスの縁が 1 画素でもあれば false。**固定値が環境依存でないことの
/// 前提条件**なので、golden と同じテストの中で確かめる。
bool _hasOnlyPureColors(DecodedPng png, List<Color> palette) {
  for (var y = 0; y < png.height; y++) {
    for (var x = 0; x < png.width; x++) {
      final p = png.at(x, y);
      final hit = palette.any(
        (c) =>
            (p.r * 255).round() == (c.r * 255).round() &&
            (p.g * 255).round() == (c.g * 255).round() &&
            (p.b * 255).round() == (c.b * 255).round(),
      );
      if (!hit) return false;
    }
  }
  return true;
}

/// URL ごとに違う素材を返す [StickerSource]。
class _ByUrlStickerSource implements StickerSource {
  _ByUrlStickerSource(this.builders);

  final Map<String, ui.Image Function()> builders;

  @override
  Future<CustomEmoji?> pick({
    required BuildContext context,
    required WidgetRef ref,
  }) async => null;

  @override
  Future<ui.Image> load(String url) async {
    final builder = builders[url];
    if (builder == null) throw StateError('unknown sticker url: $url');
    return builder();
  }
}

import 'dart:typed_data';

import 'package:flutter/painting.dart';

/// 添付画像に重ねた 1 レイヤを、**編集画面の外へ持ち出せる形**で記述する (#1129)。
///
/// 編集画面 (`ImageOverlayScreen`) の中では `_OverlayItem` が可変の状態として
/// 生きているが、画面を閉じるとそれごと消える。焼き込み済みの PNG だけを残すと
/// **再入したときに「平らな画像」が新しい元画像になり、前のレイヤを編集できない**。
/// そこで、画面を閉じるときにこの記述へ写し取り、添付に紐づけて持っておく。
///
/// ⚠⚠ **`ui.Image` を持たない。**スタンプはショートコードと URL で覚え、編集画面へ
/// 再入したときに取り直す。添付ごとに原寸画像を抱えると、下書きに数枚貼っただけで
/// ネイティブ側のメモリが積む（解放の作法は編集画面側に閉じている）。
///
/// ⚠ **投稿に使う画像は従来どおり焼き込み済みの PNG。**この記述は「もう一度編集
/// できるようにするための控え」であって、投稿経路には出てこない。
sealed class OverlayLayerSpec {
  const OverlayLayerSpec({
    required this.nx,
    required this.ny,
    required this.sizeFrac,
    required this.angle,
    required this.opacity,
    required this.visible,
    required this.locked,
  });

  /// 画像内の正規化中心座標 (0..1)。
  final double nx;
  final double ny;

  /// 画像高さに対する比率。
  final double sizeFrac;

  /// 中心まわりの回転角（ラジアン）(#946)。
  final double angle;

  /// レイヤ全体の不透明度 (#1128)。
  final double opacity;

  /// 画に出すか (#1127)。
  final bool visible;

  /// 誤操作から守るか (#1127)。
  final bool locked;
}

/// 文字 / Unicode 絵文字のレイヤ (#576)。
class TextOverlayLayerSpec extends OverlayLayerSpec {
  const TextOverlayLayerSpec({
    required this.text,
    required this.color,
    required super.nx,
    required super.ny,
    required super.sizeFrac,
    required super.angle,
    required super.opacity,
    required super.visible,
    required super.locked,
  });

  final String text;
  final Color color;
}

/// カスタム絵文字を素材にした画像スタンプのレイヤ (#883)。
///
/// ⚠ **素材は URL で覚える。**再入時にここから取り直すので、**サーバーから絵文字が
/// 消えていると復元できない**。そのときは黙って落とさず、利用者に何枚落ちたかを
/// 伝えること（焼き込み済みの画像には残っているので、完了するとそのぶんが消える）。
class StickerOverlayLayerSpec extends OverlayLayerSpec {
  const StickerOverlayLayerSpec({
    required this.shortcode,
    required this.url,
    required super.nx,
    required super.ny,
    required super.sizeFrac,
    required super.angle,
    required super.opacity,
    required super.visible,
    required super.locked,
  });

  final String shortcode;
  final String url;
}

/// 編集画面の戻り値 (#1129)。
///
/// ⚠ **焼き込み済みの [png] と、再編集のための [layers] を両方返す。**片方だけだと
/// 「サムネ・投稿に使える画像」か「もう一度編集できる状態」のどちらかが失われる。
class ImageOverlayResult {
  const ImageOverlayResult({required this.png, required this.layers});

  /// 元画像にレイヤを焼き込んだ PNG。表示・投稿はこれを使う。
  final Uint8List png;

  /// 焼き込みに使ったレイヤ列（先頭が最背面）。再入時に復元する。
  final List<OverlayLayerSpec> layers;
}

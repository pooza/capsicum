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
///
/// ⚠ **下書きにも書き出す (#1130)。**`ui.Image` を持たないのはそのための条件でも
/// あり、[toJson] / [fromJson] がそのまま永続化の形になる（受け皿は
/// `ComposeDraftAttachment`）。
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

  /// 下書きへ書き出す形 (#1130)。
  ///
  /// ⚠⚠ **項目を足したらここと [fromJson] の両方を直す。**片方だけだと「保存は
  /// されるが戻らない」（またはその逆）になる —— 編集画面側の `_specOf` /
  /// `_applySpec` と同じ対。4 箇所が対になっているので、
  /// `image_overlay_layer_json_guard_test.dart` が機械で照合している。
  Map<String, Object?> toJson();

  /// 共通項目。サブクラスの [toJson] が自分のぶんを足して返す。
  Map<String, Object?> baseJson(String type) => <String, Object?>{
    'type': type,
    'nx': nx,
    'ny': ny,
    'sizeFrac': sizeFrac,
    'angle': angle,
    'opacity': opacity,
    'visible': visible,
    'locked': locked,
  };

  /// [toJson] の逆。**読めなければ null**（投げない）。
  ///
  /// ⚠ 下書きは前の版が書いたものを読むことがあり、壊れた 1 レイヤで復元全体を
  /// 落とすと**本文まで戻らなくなる**。呼び出し側は null を捨てて先へ進む。
  static OverlayLayerSpec? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<Object?, Object?>();
    double? number(String key) {
      final value = json[key];
      return value is num ? value.toDouble() : null;
    }

    final nx = number('nx');
    final ny = number('ny');
    final sizeFrac = number('sizeFrac');
    final angle = number('angle');
    final opacity = number('opacity');
    final visible = json['visible'];
    final locked = json['locked'];
    if (nx == null ||
        ny == null ||
        sizeFrac == null ||
        angle == null ||
        opacity == null ||
        visible is! bool ||
        locked is! bool) {
      return null;
    }

    switch (json['type']) {
      case 'text':
        final text = json['text'];
        final color = json['color'];
        if (text is! String || color is! int) return null;
        return TextOverlayLayerSpec(
          text: text,
          color: Color(color),
          nx: nx,
          ny: ny,
          sizeFrac: sizeFrac,
          angle: angle,
          opacity: opacity,
          visible: visible,
          locked: locked,
        );
      case 'sticker':
        final shortcode = json['shortcode'];
        final url = json['url'];
        if (shortcode is! String || url is! String) return null;
        return StickerOverlayLayerSpec(
          shortcode: shortcode,
          url: url,
          nx: nx,
          ny: ny,
          sizeFrac: sizeFrac,
          angle: angle,
          opacity: opacity,
          visible: visible,
          locked: locked,
        );
      default:
        return null;
    }
  }
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

  @override
  Map<String, Object?> toJson() => {
    ...baseJson('text'),
    'text': text,
    // ⚠ `Color` はそのままでは JSON に載らない。ARGB の 32bit 整数で持つ
    // （`preferences_provider` のテーマ色と同じ形）。
    'color': color.toARGB32(),
  };
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

  @override
  Map<String, Object?> toJson() => {
    ...baseJson('sticker'),
    'shortcode': shortcode,
    'url': url,
  };
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

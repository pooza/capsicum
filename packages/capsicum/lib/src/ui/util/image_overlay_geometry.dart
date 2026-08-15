/// 添付画像オーバーレイ (#576 / #883) の座標計算。
///
/// エディタは同じレイヤを **2 回描く** —— 画面に fit 表示した編集用キャンバスと、
/// 原寸の書き出し用 Canvas。この 2 つが食い違うと「見たままが出ない」ので、
/// 寸法の式は必ずここを通す。レイヤ側が位置を正規化座標 (0..1)、大きさを
/// 「基準高さに対する比率」で持っているのは、基準高さを差し替えるだけで両方を
/// 賄えるようにするため。
library;

import 'dart:ui';

/// テキストレイヤの折り返し幅の、描画幅に対する比率 (#960)。書き出し側
/// (`painter.layout(maxWidth: w * この値)`) とプレビュー側
/// (`BoxConstraints(maxWidth: dispW * この値)`) の両方がこれを使う。片方だけ
/// リテラルで持つと WYSIWYG が割れるため、寸法の式と同じくここに集約する。
const double kOverlayTextWrapFraction = 0.96;

/// テキストレイヤ追加時の初期サイズ比率（基準高さに対する比率）。
const double kOverlayDefaultTextSizeFrac = 0.08;

/// スタンプ（画像レイヤ）追加時の初期サイズ比率。
const double kOverlayDefaultStickerSizeFrac = 0.2;

/// サイズ比率スライダの下限。
const double kOverlayMinSizeFrac = 0.03;

/// サイズ比率スライダの上限。テキストは行が伸びすぎないよう低め、スタンプは
/// 大きく貼れるよう高め。
const double kOverlayMaxTextSizeFrac = 0.25;
const double kOverlayMaxStickerSizeFrac = 0.8;

/// テキストアウトライン幅 = `fontSize ÷ この値`。
const double kOverlayOutlineWidthDivisor = 22;

/// スタンプ (画像レイヤ) の描画矩形を返す (#883)。
///
/// 高さは [sizeFrac] × [referenceHeight] で決め、幅は元画像の [aspect]
/// (幅 ÷ 高さ) から復元する。**幅を独立に持たない**のは、カスタム絵文字に
/// 横長のものが珍しくないため —— 幅と高さを別々に保持すると、編集画面と
/// 書き出しで丸め方が割れて縦横比が崩れる。
///
/// [center] は描画先の座標系における中心。呼び出し側が
/// `Offset(nx * width, ny * height)` を渡す。
Rect stickerOverlayRect({
  required Offset center,
  required double sizeFrac,
  required double aspect,
  required double referenceHeight,
}) {
  final height = sizeFrac * referenceHeight;
  return Rect.fromCenter(
    center: center,
    width: height * aspect,
    height: height,
  );
}

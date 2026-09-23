/// 添付画像オーバーレイ (#576 / #883) の座標計算。
///
/// エディタは同じレイヤを **2 回描く** —— 画面に fit 表示した編集用キャンバスと、
/// 原寸の書き出し用 Canvas。この 2 つが食い違うと「見たままが出ない」ので、
/// 寸法の式は必ずここを通す。レイヤ側が位置を正規化座標 (0..1)、大きさを
/// 「基準高さに対する比率」で持っているのは、基準高さを差し替えるだけで両方を
/// 賄えるようにするため。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 操作スライダの識別キー (#946)。
///
/// #883 の時点ではスライダが 1 本しか無く、テストは `find.byType(Slider)` で
/// 掴んでいた。回転を足して 2 本になったので、**どちらを動かしたいのか**を
/// 型でなくキーで名指しする。定数を画面側でなくここに置くのは、寸法まわりの
/// 取り決めと同じくテストから import させるため。
const overlaySizeSliderKey = Key('overlay_size_slider');
const overlayAngleSliderKey = Key('overlay_angle_slider');
const overlayOpacitySliderKey = Key('overlay_opacity_slider');

/// 編集キャンバス（画像と同じ矩形）の識別キー (#1126)。
///
/// ⚠ **レイヤ一覧のサムネにも同じウィジェット（[RawImage] / [Text]）が出る**ので、
/// 「プレビューに何がどの順で載っているか」を見るテストは、型で拾うと一覧の
/// ぶんまで混ざる。キャンバス配下に絞り込むための取っ手。
const overlayCanvasKey = Key('overlay_canvas');

/// レイヤ一覧の開閉ボタン (#1126) と一覧そのものの識別キー。
const overlayLayerToggleKey = Key('overlay_layer_toggle');
const overlayLayerListKey = Key('overlay_layer_list');

/// レイヤ一覧を本文の横に常設するかどうかの境目（論理 px）(#1126)。
///
/// これ以上の幅ならキャンバスの右に置き、下回るとキャンバスの下に折り畳んで
/// 開閉式にする。⚠ **分岐軸はプラットフォームではなく画面幅**（docs/CLAUDE.md）。
/// デスクトップでもウィンドウを狭めれば折り畳み側になる——capsicum は動画アプリと
/// 横並びで使われるので、狭いデスクトップウィンドウは例外ではなく常態。
const double kOverlayLayerPanelMinWidth = 600;

/// 常設時のレイヤ一覧の幅。
const double kOverlayLayerPanelWidth = 280;

/// 折り畳み時のレイヤ一覧の高さ。中身は足りなければスクロールする。
const double kOverlayLayerListCollapsedHeight = 176;

/// レイヤ一覧のサムネを収める正方形の一辺。画像はこの箱へ fit させる。
const double kOverlayLayerThumbExtent = 40;

/// 削除を取り消せる時間 (#1126 / #1131)。
///
/// ⚠⚠ **スタンプの `ui.Image` の解放をこの時間だけ遅らせる。**原寸画像はネイティブ側に
/// 積まれるので、「取り消せるかもしれない」を無期限にはできない。SnackBar が閉じる
/// のと同じ時間を上限として明示し、閉じたら必ず解放する。
const Duration kOverlayUndoWindow = Duration(seconds: 5);

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

/// 回転角スライダの範囲（ラジアン）(#946)。中央が 0（無回転）になるよう
/// ±π＝ ±180° を取る。
///
/// ⚠ **0° / 90° 付近への吸着（スナップ）は入れていない。** ミーム的な用途では
/// 「わざと少し傾ける」が主で、吸着があると狙った角度に置けない。代わりに
/// **中央が正確に 0 になる範囲**と、明示的なリセット導線を用意している
/// （スライダだけだと 0 へ戻すのが難しいため）。
const double kOverlayMaxAngle = math.pi;
const double kOverlayMinAngle = -math.pi;

/// レイヤの不透明度の既定値と下限 (#1128)。上限は 1.0。
///
/// ⚠ **下限は 0** —— 完全に透明にできる。結果は #1127 の「非表示」と一致するが、
/// **別の概念**として両方残す（非表示は「一時的に外す」、不透明度 0 は「薄さの端」）。
const double kOverlayDefaultOpacity = 1;
const double kOverlayMinOpacity = 0;

/// 不透明度をユーザーに見せる百分率表記（例 `60%`）。
String overlayOpacityLabel(double opacity) => '${(opacity * 100).round()}%';

/// 回転角をユーザーに見せる度数表記（例 `-12°`）。編集画面のラベル用。
String overlayAngleLabel(double radians) {
  final degrees = radians * 180 / math.pi;
  return '${degrees.round()}°';
}

/// 元画像を一辺 [extent] の正方形へ fit させたときの表示寸法 (#1126)。
///
/// レイヤ一覧のサムネは、レイヤを**画像ごと縮めた縮図**として描く。⚠ **これが
/// 3 回目の描画**（編集キャンバス・書き出しに続く）なので、返した高さを
/// `referenceHeight` としてそのまま [stickerOverlayRect] や文字サイズの式へ
/// 渡すこと。ここで独自に縮尺を決めると、一覧だけ縦横比や相対サイズが崩れる。
Size overlayThumbSize(
  Size imageSize, {
  double extent = kOverlayLayerThumbExtent,
}) {
  final aspect = imageSize.width / imageSize.height;
  return aspect >= 1
      ? Size(extent, extent / aspect)
      : Size(extent * aspect, extent);
}

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

/// レイヤの並べ替え (#1125 / #884-B)。**元の一覧は書き換えず**、新しい一覧を返す。
///
/// [newIndex] は `ReorderableListView.onReorderItem` の流儀、すなわち
/// **取り除いた後の挿入位置**。そのまま `insert` すればよく、補正は要らない。
///
/// ⚠⚠ **旧 `onReorder` と流儀が違う。**旧コールバックは「取り除く**前**の位置」を
/// 渡すので `newIndex > oldIndex` のとき 1 つ詰める補正が要った。#1125 で足した
/// 初版はその補正を持っていたが、**呼び出し側が無いまま（配線は #884-B）だったので
/// 誰も踏んでいなかった。**Flutter は `_handleReorderItem` の中で
/// `if (newIndex > oldIndex) newIndex -= 1;` を済ませてから `onReorderItem` を
/// 呼ぶため、補正を二重に掛けると**後ろへ動かしたとき 1 つ手前に落ちる**。
/// 同じ取り決めは `tab_management_sheet.dart` の `_reorderEntries` にも書いてある
/// (#836)。**このリポジトリでは `onReorderItem` に揃える。**
///
/// ⚠ 選択は添字ではなくレイヤの ID で持っているので、並べ替えても選択は同じ
/// レイヤについていく（添字で持つと、並べ替えた瞬間に別のレイヤを指す）。
List<T> reorderOverlayLayers<T>(List<T> items, int oldIndex, int newIndex) {
  final result = List.of(items);
  final item = result.removeAt(oldIndex);
  result.insert(newIndex.clamp(0, result.length), item);
  return result;
}

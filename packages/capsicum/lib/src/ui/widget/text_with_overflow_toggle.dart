import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 本文と「続きを読む」を **1 回のレイアウトで**並べる (#1369)。
///
/// 本文（[text]）を先にレイアウトし、表示した段落が行数の上限で切れていた
/// （`RenderParagraph.didExceedMaxLines`）ときだけ、下に [toggle] を置く。
///
/// ⚠⚠ **「続きを読む」の要否を別の `TextPainter` で測ってはいけない。**以前は
/// 素の文字列を `TextPainter` で測っていたが、文字サイズの倍率（`textScaler`）・
/// locale・カスタム絵文字などの `WidgetSpan` が表示と揃わず、表示は切れているのに
/// 「続きを読む」が出ないことがあった（文字サイズ 110% で再現）。
///
/// ⚠ **描いてから次のフレームで出し分けてもいけない。**欄の高さが 1 フレーム
/// 遅れて変わり、タイムラインのスクロール位置が跳ねる（#1032 と同じ形）。
/// だからレイアウトの中で決める。
///
/// [collapsedText] は展開中（「折り畳む」を出すか決める）に渡す、**行数の上限を
/// 付けた同じ本文**。展開中の [text] には上限が無いので、段落からは切れるかが
/// 分からない。[collapsedText] はレイアウトだけして描かない（押せない・読み上げ
/// ない・選択できない）。⚠ 「展開中は常に出す」にしてはいけない —— スレッドの
/// 対象の投稿は最初から展開して出すので、短い投稿にも「折り畳む」が出る。
class TextWithOverflowToggle extends MultiChildRenderObjectWidget {
  TextWithOverflowToggle({
    super.key,
    required Widget text,
    required Widget toggle,
    Widget? collapsedText,
  }) : super(
         children: [
           text,
           toggle,
           if (collapsedText != null)
             ExcludeSemantics(
               child: SelectionContainer.disabled(child: collapsedText),
             ),
         ],
       );

  @override
  RenderTextWithOverflowToggle createRenderObject(BuildContext context) =>
      RenderTextWithOverflowToggle();
}

class _ToggleParentData extends ContainerBoxParentData<RenderBox> {}

class RenderTextWithOverflowToggle extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ToggleParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ToggleParentData> {
  bool _showsToggle = false;

  /// 直近のレイアウトで「続きを読む」（展開中は「折り畳む」）を置いたか。
  bool get showsToggle => _showsToggle;

  RenderBox get _text => firstChild!;
  RenderBox get _toggle => childAfter(firstChild!)!;

  /// 測る専用の子（展開中だけ）。
  RenderBox? get _collapsed => childAfter(_toggle);

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ToggleParentData) {
      child.parentData = _ToggleParentData();
    }
  }

  /// [node] の下で最初に見つかる段落が、行数の上限で切れていたか。
  ///
  /// ⚠ 前順で探すので、本文の段落が先に当たる（カスタム絵文字などの
  /// `WidgetSpan` の中の段落は、本文の段落の子なので後になる）。
  /// `SelectionArea` で包んでいても、その下の段落を見つける。
  static bool _didExceedMaxLines(RenderObject node) =>
      _findParagraph(node) ?? false;

  static bool? _findParagraph(RenderObject node) {
    if (node is RenderParagraph) return node.didExceedMaxLines;
    bool? found;
    node.visitChildren((child) {
      found ??= _findParagraph(child);
    });
    return found;
  }

  @override
  void performLayout() {
    final childConstraints = BoxConstraints(maxWidth: constraints.maxWidth);
    final text = _text;
    final toggle = _toggle;

    text.layout(childConstraints, parentUsesSize: true);
    (text.parentData! as _ToggleParentData).offset = Offset.zero;
    final collapsed = _collapsed;
    if (collapsed != null) {
      collapsed.layout(childConstraints);
      (collapsed.parentData! as _ToggleParentData).offset = Offset.zero;
      _showsToggle = _didExceedMaxLines(collapsed);
    } else {
      _showsToggle = _didExceedMaxLines(text);
    }

    var width = text.size.width;
    var height = text.size.height;
    if (_showsToggle) {
      toggle.layout(childConstraints, parentUsesSize: true);
      (toggle.parentData! as _ToggleParentData).offset = Offset(0, height);
      width = math.max(width, toggle.size.width);
      height += toggle.size.height;
    } else {
      toggle.layout(BoxConstraints.tight(Size.zero));
    }
    size = constraints.constrain(Size(width, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final textData = _text.parentData! as _ToggleParentData;
    context.paintChild(_text, offset + textData.offset);
    if (_showsToggle) {
      final toggleData = _toggle.parentData! as _ToggleParentData;
      context.paintChild(_toggle, offset + toggleData.offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (_showsToggle && _hitChild(_toggle, result, position)) return true;
    return _hitChild(_text, result, position);
  }

  bool _hitChild(RenderBox child, BoxHitTestResult result, Offset position) {
    final data = child.parentData! as _ToggleParentData;
    return result.addWithPaintOffset(
      offset: data.offset,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    visitor(_text);
    if (_showsToggle) visitor(_toggle);
  }

  // ⚠ 内在寸法は本文だけで答える（「続きを読む」の要否はレイアウトしないと
  // 分からない）。タイムラインの欄は内在寸法を問わないので、ずれても実害は無い。
  @override
  double computeMinIntrinsicWidth(double height) =>
      _text.getMinIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _text.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) =>
      _text.getMinIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _text.getMaxIntrinsicHeight(width);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      constraints.constrain(
        _text.getDryLayout(BoxConstraints(maxWidth: constraints.maxWidth)),
      );
}

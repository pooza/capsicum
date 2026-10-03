import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../provider/preferences_provider.dart' show minDeckColumnWidth;

/// 幅の上限は下限の何倍か。広い画面ではカラムを太くせず**本数を増やす**。
const double kDeckMaxColumnWidthFactor = 1.5;

/// デッキの横の割り付け。
@immutable
class DeckLayout {
  const DeckLayout({required this.visibleColumns, required this.columnWidth});

  /// 画面に同時に入るカラム数（1 以上）。
  final int visibleColumns;

  /// 各カラムの幅。
  final double columnWidth;

  @override
  bool operator ==(Object other) =>
      other is DeckLayout &&
      other.visibleColumns == visibleColumns &&
      other.columnWidth == columnWidth;

  @override
  int get hashCode => Object.hash(visibleColumns, columnWidth);

  @override
  String toString() => 'DeckLayout($visibleColumns × $columnWidth)';
}

/// 使える幅とカラム数から、割り付けを決める (#1092)。
///
/// 参考実装（SubwayTooter `ActMainColumns.kt` の `resizeColumnWidth()`）と同じ算法:
///
/// - **2 本入らないなら 1 カラムで全幅**（そのままページャとして振る舞う）
/// - 入るなら**下限から本数を決め、余りを各カラムへ均等配分**
/// - ⚠ **1 本あたりの幅は下限の [kDeckMaxColumnWidthFactor] 倍で頭打ち**
/// - カラムが本数より少なければ、その本数で割る（ただし上限は同じ）
///
/// ⚠⚠ **「狭幅モード」を作らない。**同じ 1 つの部品が幅次第で 1 カラムにも
/// N カラムにもなる（参考実装 §1）。
///
/// [minColumnWidth] はユーザー設定（`deckColumnWidthProvider`）。
/// ⚠ [minDeckColumnWidth]（375px）より下げられない。
DeckLayout computeDeckLayout({
  required double availableWidth,
  required int columnCount,
  double minColumnWidth = minDeckColumnWidth,
}) {
  final minWidth = math.max(minColumnWidth, minDeckColumnWidth);
  if (availableWidth < minWidth * 2) {
    return DeckLayout(visibleColumns: 1, columnWidth: availableWidth);
  }
  var visible = (availableWidth / minWidth).floor();
  if (columnCount > 0 && columnCount < visible) visible = columnCount;
  final width = math.min(
    availableWidth / visible,
    minWidth * kDeckMaxColumnWidthFactor,
  );
  return DeckLayout(visibleColumns: visible, columnWidth: width);
}

/// カラムの境界で止まる横スクロール (#1092)。
///
/// 1 カラムのときはページャ、複数カラムのときは「列単位で送る」になる。
/// `PageScrollPhysics` と同じ形で、ページ幅の代わりに [columnWidth] を使う。
class DeckSnapScrollPhysics extends ScrollPhysics {
  const DeckSnapScrollPhysics({required this.columnWidth, super.parent});

  final double columnWidth;

  @override
  DeckSnapScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      DeckSnapScrollPhysics(
        columnWidth: columnWidth,
        parent: buildParent(ancestor),
      );

  double _targetPixels(
    ScrollMetrics position,
    Tolerance tolerance,
    double velocity,
  ) {
    var index = position.pixels / columnWidth;
    if (velocity < -tolerance.velocity) {
      index -= 0.5;
    } else if (velocity > tolerance.velocity) {
      index += 0.5;
    }
    return (index.roundToDouble() * columnWidth).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    final target = _targetPixels(position, tolerance, velocity);
    if (target != position.pixels) {
      return ScrollSpringSimulation(
        spring,
        position.pixels,
        target,
        velocity,
        tolerance: tolerance,
      );
    }
    return null;
  }

  @override
  bool get allowImplicitScrolling => false;
}

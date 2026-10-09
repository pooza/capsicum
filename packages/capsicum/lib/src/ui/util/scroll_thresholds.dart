import 'package:flutter/widgets.dart';

/// 一覧の末尾からこの距離まで来たら、続きを読みに行く (#1235)。
///
/// ⚠ 17 画面に `maxScrollExtent - 600` が名前無しで写されていた。画面ごとに
/// 変える理由は無いので、動かすならここだけを動かす。
const double kLoadMoreScrollThreshold = 600;

/// 一覧の先頭からこの距離までを「先頭付近」とみなす (#1235)。
///
/// 先頭付近に居る間はライブの新着を一覧へ直接入れ、離れている間は未表示
/// バッファへ退避する（読んでいる最中に行が動くのを防ぐ・#296）。
const double kNearTopScrollThreshold = 200;

/// 続きを読みに行く位置まで来たか。
bool shouldLoadMore(ScrollPosition position) =>
    position.pixels >= position.maxScrollExtent - kLoadMoreScrollThreshold;

/// 先頭付近に居るか。
bool isNearTop(ScrollPosition position) =>
    position.pixels <= kNearTopScrollThreshold;

/// 「先頭付近に居るか」が切り替わったときだけ知らせる (#1235)。
///
/// スクロールの通知は 1 フレームごとに来るので、毎回 notifier を叩かない。
class NearTopTracker {
  bool _nearTop = true;

  /// [position] を見て、先頭付近かどうかが変わっていたら [onChanged] を呼ぶ。
  void update(ScrollPosition position, void Function(bool nearTop) onChanged) {
    final nearTop = isNearTop(position);
    if (nearTop == _nearTop) return;
    _nearTop = nearTop;
    onChanged(nearTop);
  }
}

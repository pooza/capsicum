import 'package:flutter/material.dart';

/// 一覧の先頭・末尾へ飛ぶボタン（△▽）(#1244)。
///
/// タブ UI の右下と、デッキの各カラムの右下に置く。
///
/// - △ は先頭から離れたときだけ出す（先頭に居るときは押しても何も起きない）
/// - ▽ は**読み込み済みの末尾**へ飛ぶ。そこが続きを読みに行く位置なので、
///   飛んだ先で追加読み込みが起きる
///
/// ⚠ **`heroTag` を付けない。**同じ画面に 2 つ（デッキではカラムの数 × 2）並ぶ
/// ので、既定の共有タグのままだと画面遷移のたびに Hero が衝突して落ちる。
class ScrollJumpButtons extends StatelessWidget {
  const ScrollJumpButtons({
    super.key,
    required this.showTop,
    required this.onTop,
    required this.onBottom,
  });

  /// 先頭から離れているか。
  final bool showTop;
  final VoidCallback onTop;
  final VoidCallback onBottom;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (showTop) ...[
        FloatingActionButton.small(
          heroTag: null,
          onPressed: onTop,
          tooltip: '先頭へ',
          child: const Icon(Icons.arrow_upward),
        ),
        const SizedBox(height: 8),
      ],
      FloatingActionButton.small(
        heroTag: null,
        onPressed: onBottom,
        tooltip: '末尾へ',
        child: const Icon(Icons.arrow_downward),
      ),
    ],
  );
}

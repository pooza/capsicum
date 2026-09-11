import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/preferences_provider.dart';

/// 上端のハンドルをドラッグして高さを変えられるピッカーシート。決めた高さは
/// [heightProvider] に記憶して次回も維持する。
///
/// 挿入ピッカー (#690) とリアクションピッカー (#907) で共有する。記憶先の
/// provider を差し替えることで、用途ごとに別々の高さを覚える。
class ResizablePickerSheet extends ConsumerStatefulWidget {
  /// キーボードを含まない画面全体の高さ。比率の基準に使う。
  final double screenHeight;

  /// 高さ（利用可能領域に対する比率）の記憶先。
  final NotifierProvider<PickerSheetHeightNotifier, double> heightProvider;

  final Widget child;

  const ResizablePickerSheet({
    super.key,
    required this.screenHeight,
    required this.heightProvider,
    required this.child,
  });

  @override
  ConsumerState<ResizablePickerSheet> createState() =>
      _ResizablePickerSheetState();
}

class _ResizablePickerSheetState extends ConsumerState<ResizablePickerSheet> {
  late double _factor = ref.read(widget.heightProvider);

  @override
  Widget build(BuildContext context) {
    // 検索ボックスで IME が開くとシート下半分がキーボードに隠れ、候補リストの
    // 可視領域が数件に潰れてスクロールも届かなくなる。キーボード高さ分だけ
    // 下にパディングしてシートをその上へ押し上げる (#614)。viewInsets は
    // モーダルルート側で更新されるため、IME 開閉に追従させるには本ウィジェット
    // の context を見る。
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    // ⚠⚠ **ナビゲーションバーぶんも足す (#1062)。**以前はキーボードだけを見て
    // おり、**絵文字グリッドの最下段がナビゲーションバーのボタンと重なって**
    // いた。リアクションは最頻の操作なので、#1037 と同じ体験になる。
    //
    // ⚠ **二重には入らない。**`MediaQuery.padding` は `viewPadding` から
    // `viewInsets` を引いた残りなので、キーボードがナビゲーションバーを覆って
    // いる間は 0 になる（`BottomSafeArea` の doc と同じ理由）。
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // 高さは画面高ではなく利用可能領域（画面 - キーボード - 下端 inset）基準に
    // する。フル投稿フォーム（closeOnSelect=false）では本文にフォーカスしたまま
    // シートを開くためキーボードが残り、画面高基準だと本文が隠れる。利用可能
    // 領域基準ならキーボード開時にシートも縮み、本文の可視領域が回復する
    // (#689 / iPhone 実機報告)。
    //
    // ⚠ **`bottomInset` も引く。**引かずに下の Padding だけ足すと、
    // `_factor` が 1 に近いときシート全体（高さ + padding）が画面高を超える。
    final available = widget.screenHeight - keyboardInset - bottomInset;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset + bottomInset),
      child: SizedBox(
        height: available * _factor,
        child: Column(
          children: [
            _buildDragHandle(available),
            Expanded(child: widget.child),
          ],
        ),
      ),
    );
  }

  /// 上端のドラッグハンドル。上方向ドラッグで高さを増やし、離した時点で記憶する。
  Widget _buildDragHandle(double available) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) {
        if (available <= 0) return;
        setState(() {
          // 上ドラッグ (dy<0) で高さ増。ハンドルが指に追従するよう available
          // 基準の比率で増減し、clamp する。
          _factor = (_factor - details.delta.dy / available).clamp(
            kMinPickerSheetHeight,
            kMaxPickerSheetHeight,
          );
        });
      },
      onVerticalDragEnd: (_) {
        ref.read(widget.heightProvider.notifier).set(_factor);
      },
      child: Container(
        width: double.infinity,
        // 見た目のグリップは 40×4 のまま、当たり判定だけ広げる (#878)。上下 20 +
        // グリップ 4 = 約 44px で Apple HIG 推奨のタッチ領域を満たす。小画面
        // iPhone で「上げる」操作が掴みづらいという報告への対応。
        padding: const EdgeInsets.symmetric(vertical: 20),
        alignment: Alignment.center,
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

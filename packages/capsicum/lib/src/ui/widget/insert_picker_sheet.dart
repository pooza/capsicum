import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../util/mouse_drag_scroll_behavior.dart';
import 'emoji_picker.dart';

/// 投稿本文・簡易投稿バー共通の挿入ピッカー起動経路 (#614)。
///
/// 絵文字 (カスタム / Unicode) に加え、モロヘイヤ導入サーバーでは劇中ワード等の
/// 拡張タブを同じシートから開く。compose と簡易バーで実装を 1 箇所に集約し、
/// 拡張タブが両画面で自動的に使えるようにする (設計 doc: compose-suggest-design.md)。
///
/// 挿入対象は呼び出し側ごとに異なる (compose / 簡易バーで別 controller) ため、
/// 挿入処理は [onSelected] コールバックに委ね、本ランチャはシート表示のみを担う。
///
/// [closeOnSelect] が true のときは 1 件選択した時点でシートを閉じる。簡易投稿
/// バーは 1 タップ挿入が主眼なので即閉じ、compose は連続挿入のため開いたまま、と
/// 呼び出し側で使い分ける (#614)。
Future<void> showInsertPickerSheet({
  required BuildContext context,
  required WidgetRef ref,
  required ValueChanged<String> onSelected,
  bool closeOnSelect = false,
}) async {
  final account = ref.read(currentAccountProvider);
  final adapter = account?.adapter;
  if (adapter == null) return;
  // マウスドラッグスクロールはユーザーのオプトイン設定 (#574)。トラックパッド
  // 2 本指スワイプとの両立が崩れうるため無条件には噛ませず、home_screen と
  // 同じ設定値で出し分ける。
  final mouseDragEnabled = ref.read(mouseDragScrollProvider);
  // 画面高は親 context から取る（sheet 表示後もキーボード開閉で不変）。
  final screenHeight = MediaQuery.of(context).size.height;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      // モーダルシートは MaterialApp のグローバル scrollBehavior 配下に無く、
      // 既定の dragDevices はマウスを含まないため、デスクトップで候補リストを
      // マウスドラッグしてもスクロールしない。設定 ON のときだけ home_screen と
      // 同じ手当てでマウスドラッグを有効化する (#574 / #614)。
      final picker = _maybeMouseDrag(
        enabled: mouseDragEnabled,
        child: EmojiPicker(
          adapter: adapter as BackendAdapter,
          host: account!.key.host,
          mulukhiya: account.mulukhiya,
          accessToken: account.userSecret.accessToken,
          onSelected: (value) {
            onSelected(value);
            if (closeOnSelect) Navigator.of(sheetContext).pop();
          },
        ),
      );
      return _InsertPickerSheet(screenHeight: screenHeight, child: picker);
    },
  );
}

/// 挿入ピッカーシート本体。上端のハンドルをドラッグして高さを変えられ、
/// 決めた高さは [insertPickerHeightProvider] に記憶して次回も維持する (#690)。
class _InsertPickerSheet extends ConsumerStatefulWidget {
  /// キーボードを含まない画面全体の高さ。比率の基準に使う。
  final double screenHeight;
  final Widget child;

  const _InsertPickerSheet({required this.screenHeight, required this.child});

  @override
  ConsumerState<_InsertPickerSheet> createState() => _InsertPickerSheetState();
}

class _InsertPickerSheetState extends ConsumerState<_InsertPickerSheet> {
  late double _factor = ref.read(insertPickerHeightProvider);

  @override
  Widget build(BuildContext context) {
    // 検索ボックスで IME が開くとシート下半分がキーボードに隠れ、候補リストの
    // 可視領域が数件に潰れてスクロールも届かなくなる。キーボード高さ分だけ
    // 下にパディングしてシートをその上へ押し上げる (#614)。viewInsets は
    // モーダルルート側で更新されるため、IME 開閉に追従させるには本ウィジェット
    // の context を見る。
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    // 高さは画面高ではなく利用可能領域（画面 - キーボード）基準にする。
    // フル投稿フォーム（closeOnSelect=false）では本文にフォーカスしたまま
    // シートを開くためキーボードが残り、画面高基準だと本文が隠れる。利用可能
    // 領域基準ならキーボード開時にシートも縮み、本文の可視領域が回復する
    // (#689 / iPhone 実機報告)。
    final available = widget.screenHeight - keyboardInset;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
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
            kMinInsertPickerHeight,
            kMaxInsertPickerHeight,
          );
        });
      },
      onVerticalDragEnd: (_) {
        ref.read(insertPickerHeightProvider.notifier).set(_factor);
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 8),
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

/// [enabled] が true のときだけ [MouseDragScrollBehavior] を噛ませる。
/// home_screen の `mouseDragEnabled ? ScrollConfiguration(...) : child` と同形。
Widget _maybeMouseDrag({required bool enabled, required Widget child}) {
  if (!enabled) return child;
  return ScrollConfiguration(
    behavior: const MouseDragScrollBehavior(),
    child: child,
  );
}

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../util/mouse_drag_scroll_behavior.dart';
import 'emoji_picker.dart';
import 'resizable_picker_sheet.dart';

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
      return ResizablePickerSheet(
        screenHeight: screenHeight,
        heightProvider: insertPickerHeightProvider,
        child: picker,
      );
    },
  );
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

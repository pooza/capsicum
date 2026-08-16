import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import 'emoji_picker.dart';
import 'picker_sheet_account_context.dart';
import 'resizable_picker_sheet.dart';

/// リアクション先が対応しているかの判定。既定は [ReactionSupport]（投稿への
/// リアクション）で、お知らせへのリアクションだけ [AnnouncementReactionSupport]
/// を要求する。
typedef ReactionPickerGuard =
    bool Function(DecentralizedBackendAdapter adapter);

/// リアクション用の絵文字ピッカーをボトムシートで開く共通経路 (#907)。
///
/// 投稿 (post_tile / post_touch_action_row) / 通知 (notification_tile) /
/// お知らせ (announcement_tile) / メッセージ (chat_reaction_bar) の 5 箇所が
/// それぞれ画面高 50% 固定でシートを組んでいたのを 1 箇所に寄せ、あわせて
/// 挿入ピッカー (#690) と同じ「上端ハンドルで高さ調整＋記憶」を付ける。
///
/// 高さの記憶先は [reactionPickerHeightProvider] で、挿入ピッカーとは**別**に
/// 覚える（挿入は連続入力、リアクションは 1 タップで閉じる、と用途が違うため）。
///
/// 選択された絵文字は [onSelected] に渡す。シートは選択時点で閉じるので、
/// 呼び出し側で pop する必要はない。
Future<void> showReactionPickerSheet({
  required BuildContext context,
  required WidgetRef ref,
  required ValueChanged<String> onSelected,
  ReactionPickerGuard? canReact,
}) async {
  final account = ref.read(currentAccountProvider);
  final adapter = account?.adapter;
  if (account == null || adapter == null) return;
  final guard = canReact ?? (a) => a is ReactionSupport;
  if (!guard(adapter)) return;

  // シート builder / onSelected の遅延実行に備えた退避（#739 の詳細は
  // [PickerSheetAccountContext]）。
  final picker = PickerSheetAccountContext.capture(
    context: context,
    account: account,
  );

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // builder 自身の context を使う。外側の context を握ると、タイルが
    // deactivate / 再描画されて context が外れたとき MediaQuery._of が null
    // check で fatal になる (#683 / Sentry CAPSICUM-2T)。pop も同様に寄せる。
    builder: (sheetContext) => ResizablePickerSheet(
      screenHeight: picker.screenHeight,
      heightProvider: reactionPickerHeightProvider,
      child: EmojiPicker(
        adapter: picker.backend,
        host: picker.host,
        mulukhiya: picker.mulukhiya,
        accessToken: picker.accessToken,
        forReaction: true,
        onSelected: (emoji) {
          Navigator.of(sheetContext).pop();
          onSelected(emoji);
        },
      ),
    ),
  );
}

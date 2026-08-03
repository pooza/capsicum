import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import 'emoji_picker.dart';
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

  // シート builder / onSelected は遅延実行される。実行時点で
  // currentAccountProvider が入れ替わっていても安全なよう、ここで確定した
  // 非 null 値をローカルへ退避し、closure 内で `!` / `as` を再評価しない
  // (#739 / Sentry CAPSICUM-32: closure 実行時の Null check operator クラッシュ)。
  final backend = adapter as BackendAdapter;
  final host = account.key.host;
  final mulukhiya = account.mulukhiya;
  final accessToken = account.userSecret.accessToken;
  // 画面高は親 context から取る（sheet 表示後もキーボード開閉で不変）。
  final screenHeight = MediaQuery.of(context).size.height;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // builder 自身の context を使う。外側の context を握ると、タイルが
    // deactivate / 再描画されて context が外れたとき MediaQuery._of が null
    // check で fatal になる (#683 / Sentry CAPSICUM-2T)。pop も同様に寄せる。
    builder: (sheetContext) => ResizablePickerSheet(
      screenHeight: screenHeight,
      heightProvider: reactionPickerHeightProvider,
      child: EmojiPicker(
        adapter: backend,
        host: host,
        mulukhiya: mulukhiya,
        accessToken: accessToken,
        forReaction: true,
        onSelected: (emoji) {
          Navigator.of(sheetContext).pop();
          onSelected(emoji);
        },
      ),
    ),
  );
}

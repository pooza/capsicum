import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import 'emoji_picker.dart';

/// chat メッセージの reaction を表示するバー (#612)。DM・ルーム双方の
/// メッセージバブルから共用する。
///
/// [ChatMessage.reactions] は `{reaction, user}` の個別配列なので、reaction
/// 文字列ごとに集計してチップを並べる。自分が付けた reaction はハイライトし、
/// タップで [onToggle] を呼んで付け外しする。
class ChatReactionBar extends StatelessWidget {
  final ChatMessage message;

  /// 自分の userId。自分の reaction 判定 (ハイライト) に使う。
  final String? myUserId;

  /// カスタム絵文字 URL のフォールバック解決に使うローカルサーバー host。
  final String? host;

  /// reaction チップのタップ時に呼ばれる。引数は reaction 文字列
  /// (`:shortcode:` または Unicode 絵文字)。
  final void Function(String reaction) onToggle;

  /// チップのタップを受け付けるか。自分のメッセージは Misskey 仕様で
  /// 自己リアクションが一律禁止 (必ず 500) なので、表示のみにして
  /// タップ無効にする (#612)。
  final bool interactive;

  const ChatReactionBar({
    super.key,
    required this.message,
    required this.onToggle,
    this.myUserId,
    this.host,
    this.interactive = true,
  });

  @override
  Widget build(BuildContext context) {
    if (message.reactions.isEmpty) return const SizedBox.shrink();

    // reaction 文字列ごとに件数と「自分が付けたか」を集計する。挿入順を保つため
    // LinkedHashMap (通常の Map リテラル) を使う。
    final counts = <String, int>{};
    final mine = <String>{};
    for (final r in message.reactions) {
      counts[r.reaction] = (counts[r.reaction] ?? 0) + 1;
      if (myUserId != null && r.user.id == myUserId) mine.add(r.reaction);
    }

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: counts.entries
          .map(
            (e) => _ReactionChip(
              reaction: e.key,
              count: e.value,
              isMine: mine.contains(e.key),
              host: host,
              emojis: message.emojis,
              onTap: interactive ? () => onToggle(e.key) : null,
            ),
          )
          .toList(),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  final String reaction;
  final int count;
  final bool isMine;
  final String? host;
  final Map<String, String> emojis;
  // null なら表示のみ (タップ無効)。自分のメッセージで使う (#612)。
  final VoidCallback? onTap;

  const _ReactionChip({
    required this.reaction,
    required this.count,
    required this.isMine,
    required this.host,
    required this.emojis,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isMine ? scheme.primaryContainer : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isMine ? scheme.primary : scheme.outlineVariant,
            width: isMine ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildEmoji(context),
            const SizedBox(width: 4),
            Text(
              '$count',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: isMine ? scheme.onPrimaryContainer : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmoji(BuildContext context) {
    // `:shortcode:` 形式ならカスタム絵文字として URL 解決を試みる。message.emojis
    // (本文と同梱の shortcode→URL) を優先し、無ければローカル host の規約 URL に
    // フォールバックする (content_parser と同じ方針)。解決できなければ素のテキスト。
    if (reaction.startsWith(':') && reaction.endsWith(':')) {
      final shortcode = reaction.substring(1, reaction.length - 1);
      final url =
          emojis[shortcode] ??
          (host != null ? 'https://$host/emoji/$shortcode.webp' : null);
      if (url != null) {
        return Image.network(
          url,
          height: 18,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => Text(reaction),
        );
      }
    }
    return Text(reaction, style: const TextStyle(fontSize: 16));
  }
}

/// reaction 用の絵文字ピッカーをボトムシートで開く (#612)。post の
/// リアクションピッカー (post_touch_action_row) と同じ構成で、選択された
/// 絵文字を [onPicked] に渡す。
///
/// 高さは「画面 - キーボード」基準にして、IME が残っていてもメッセージが
/// 隠れすぎないようにする (#689 と同方針)。
void showChatReactionPicker({
  required BuildContext context,
  required WidgetRef ref,
  required void Function(String reaction) onPicked,
}) {
  final account = ref.read(currentAccountProvider);
  final adapter = account?.adapter;
  if (adapter is! ReactionSupport) return;

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      final screenHeight = MediaQuery.of(context).size.height;
      final keyboardInset = MediaQuery.of(sheetContext).viewInsets.bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: SizedBox(
          height: (screenHeight - keyboardInset) * 0.5,
          child: EmojiPicker(
            adapter: adapter as BackendAdapter,
            host: account!.key.host,
            mulukhiya: account.mulukhiya,
            accessToken: account.userSecret.accessToken,
            forReaction: true,
            onSelected: (emoji) {
              Navigator.pop(sheetContext);
              onPicked(emoji);
            },
          ),
        ),
      );
    },
  );
}

/// メッセージ長押し時のアクションシート (#612)。
///
/// 「リアクション」は [canReact] が true のメッセージにのみ出す。自分の
/// メッセージは Misskey 仕様で自己リアクションが一律禁止 (必ず 500) なので
/// 出さない。「削除」は自分のメッセージ ([canDelete]) にのみ出す。両方とも
/// false なら何も出さずシートを開かない。
Future<void> showChatMessageActions({
  required BuildContext context,
  required bool canDelete,
  required VoidCallback onReact,
  bool canReact = true,
  VoidCallback? onDelete,
}) {
  if (!canReact && !canDelete) return Future<void>.value();
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canReact)
            ListTile(
              leading: const Icon(Icons.add_reaction_outlined),
              title: const Text('リアクション'),
              onTap: () {
                Navigator.pop(sheetContext);
                onReact();
              },
            ),
          if (canDelete)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('削除'),
              onTap: () {
                Navigator.pop(sheetContext);
                onDelete?.call();
              },
            ),
        ],
      ),
    ),
  );
}

import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../provider/preferences_provider.dart';
import 'reaction_picker_sheet.dart';

/// chat メッセージの reaction を表示するバー (#612)。DM・ルーム双方の
/// メッセージバブルから共用する。
///
/// [ChatMessage.reactions] は `{reaction, user}` の個別配列なので、reaction
/// 文字列ごとに集計してチップを並べる。自分が付けた reaction はハイライトし、
/// タップで [onToggle] を呼んで付け外しする。
class ChatReactionBar extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    if (message.reactions.isEmpty) return const SizedBox.shrink();

    // reaction 文字列ごとに件数と「自分が付けたか」を集計する。挿入順を保つため
    // LinkedHashMap (通常の Map リテラル) を使う。
    final counts = <String, int>{};
    final mine = <String>{};
    for (final r in message.reactions) {
      counts[r.reaction] = (counts[r.reaction] ?? 0) + 1;
      if (myUserId != null && r.user.id == myUserId) mine.add(r.reaction);
    }

    // reaction チップの絵文字にもカスタム絵文字サイズ設定を反映する (#852)。
    final emojiSize = ref.watch(emojiSizeProvider);

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
              emojiSize: emojiSize,
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
  final double emojiSize;
  // null なら表示のみ (タップ無効)。自分のメッセージで使う (#612)。
  final VoidCallback? onTap;

  const _ReactionChip({
    required this.reaction,
    required this.count,
    required this.isMine,
    required this.host,
    required this.emojis,
    required this.emojiSize,
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
          height: emojiSize,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => _fallbackText(),
        );
      }
      // URL を解決できなかったショートコードは、生のまま出すしかない fallback。
      return _fallbackText();
    }
    // Unicode 絵文字はここが通常表示（画像に落とせなかったのではない）。隣に
    // 並ぶカスタム絵文字の画像が `height: emojiSize` なので、揃うよう等倍で描く。
    return Text(reaction, style: TextStyle(fontSize: emojiSize));
  }

  Widget _fallbackText() => Text(
    reaction,
    style: TextStyle(fontSize: emojiSize * AppConstants.emojiFallbackTextScale),
  );
}

/// reaction 用の絵文字ピッカーをボトムシートで開く (#612)。選択された絵文字を
/// [onPicked] に渡す。
///
/// 実体は投稿・通知・お知らせと共通の [showReactionPickerSheet] (#907)。
/// メッセージ画面側の呼び出し名を保つためのラッパで、高さ調整・記憶・
/// キーボード追従はすべて共通シートが持つ。
void showChatReactionPicker({
  required BuildContext context,
  required WidgetRef ref,
  required void Function(String reaction) onPicked,
}) {
  unawaited(
    showReactionPickerSheet(context: context, ref: ref, onSelected: onPicked),
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

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/timeline_provider.dart';
import 'emoji_picker.dart';


class PostTile extends ConsumerWidget {
  final Post post;
  final bool tappable;

  const PostTile({super.key, required this.post, this.tappable = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayPost = post.reblog ?? post;
    return InkWell(
      onTap: tappable ? () => context.push('/post', extra: post) : null,
      onLongPress: () => _showActionMenu(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundImage:
                  displayPost.author.avatarUrl != null
                      ? NetworkImage(displayPost.author.avatarUrl!)
                      : null,
              child:
                  displayPost.author.avatarUrl == null
                      ? Text(
                        displayPost.author.username[0].toUpperCase(),
                      )
                      : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (post.reblog != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${post.author.displayName ?? post.author.username} がブースト',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  Text(
                    displayPost.author.displayName ??
                        displayPost.author.username,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _stripHtml(displayPost.content ?? ''),
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (displayPost.reactions.isNotEmpty)
                    _ReactionChips(
                      post: displayPost,
                      onToggle: (emoji) => _toggleReaction(context, ref, emoji),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleReaction(BuildContext context, WidgetRef ref, String emoji) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! ReactionSupport) return;

    final reactionAdapter = adapter as ReactionSupport;
    final targetPost = post.reblog ?? post;
    final messenger = ScaffoldMessenger.of(context);

    if (targetPost.myReaction == emoji) {
      _runReactionAction(
        ref,
        messenger,
        adapter,
        targetPost.id,
        () => reactionAdapter.removeReaction(targetPost.id, emoji),
        'リアクションを取り消しました',
      );
    } else {
      _runReactionAction(
        ref,
        messenger,
        adapter,
        targetPost.id,
        () => reactionAdapter.addReaction(targetPost.id, emoji),
        'リアクションしました',
      );
    }
  }

  void _showActionMenu(BuildContext context, WidgetRef ref) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    final targetPost = post.reblog ?? post;
    final messenger = ScaffoldMessenger.of(context);
    final isMisskey = adapter is ReactionSupport;
    final boostLabel = isMisskey ? 'リノート' : 'ブースト';
    final bookmarkLabel = isMisskey ? 'お気に入り' : 'ブックマーク';

    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (adapter is FavoriteSupport)
              ListTile(
                leading: const Icon(Icons.star_outline),
                title: const Text('お気に入り'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _runAction(
                    messenger,
                    () => (adapter as FavoriteSupport)
                        .favoritePost(targetPost.id),
                    'お気に入りに追加しました',
                  );
                },
              ),
            if (adapter is ReactionSupport)
              ListTile(
                leading: const Icon(Icons.add_reaction_outlined),
                title: const Text('リアクション'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showEmojiPicker(context, ref);
                },
              ),
            ListTile(
              leading: const Icon(Icons.repeat),
              title: Text(boostLabel),
              onTap: () {
                Navigator.pop(sheetContext);
                _runAction(
                  messenger,
                  () => adapter.repeatPost(targetPost.id),
                  '$boostLabelしました',
                );
              },
            ),
            if (adapter is BookmarkSupport)
              ListTile(
                leading: const Icon(Icons.bookmark_outline),
                title: Text(bookmarkLabel),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _runAction(
                    messenger,
                    () => (adapter as BookmarkSupport)
                        .bookmarkPost(targetPost.id),
                    '$bookmarkLabelに追加しました',
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showEmojiPicker(BuildContext context, WidgetRef ref) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ReactionSupport) return;

    final targetPost = post.reblog ?? post;
    final messenger = ScaffoldMessenger.of(context);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.5,
        child: EmojiPicker(
          adapter: adapter as BackendAdapter,
          onSelected: (emoji) {
            Navigator.pop(context);
            _runReactionAction(
              ref,
              messenger,
              adapter as BackendAdapter,
              targetPost.id,
              () => (adapter as ReactionSupport)
                  .addReaction(targetPost.id, emoji),
              'リアクションしました',
            );
          },
        ),
      ),
    );
  }

  Future<void> _runReactionAction(
    WidgetRef ref,
    ScaffoldMessengerState messenger,
    BackendAdapter adapter,
    String postId,
    Future<void> Function() action,
    String successMessage,
  ) async {
    try {
      await action();
      // Refetch the post and update the timeline.
      final updated = await adapter.getPostById(postId);
      ref.read(timelineProvider.notifier).updatePost(updated);
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('エラー: $e')));
    }
  }

  Future<void> _runAction(
    ScaffoldMessengerState messenger,
    Future<void> Function() action,
    String successMessage,
  ) async {
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('エラー: $e')));
    }
  }

  /// Minimal HTML tag stripping for display.
  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</p>\s*<p>'), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '');
  }
}

class _ReactionChips extends StatelessWidget {
  final Post post;
  final ValueChanged<String> onToggle;

  const _ReactionChips({required this.post, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: post.reactions.entries.map((entry) {
          final isMyReaction = post.myReaction == entry.key;
          // Misskey reaction keys: ":name@.:" for custom, unicode for built-in.
          // reactionEmojis keys vary: "name@." or "name" (without colons).
          final strippedKey = entry.key.startsWith(':') &&
                  entry.key.endsWith(':')
              ? entry.key.substring(1, entry.key.length - 1)
              : entry.key;
          final emojiUrl = post.reactionEmojis[strippedKey] ??
              post.reactionEmojis[strippedKey.replaceAll('@.', '')];
          return ActionChip(
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            side: isMyReaction
                ? BorderSide(color: theme.colorScheme.primary)
                : null,
            backgroundColor:
                isMyReaction ? theme.colorScheme.primaryContainer : null,
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (emojiUrl != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Image.network(
                      emojiUrl,
                      width: 18,
                      height: 18,
                      errorBuilder: (_, _, _) => Text(
                        entry.key,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(entry.key, style: const TextStyle(fontSize: 14)),
                  ),
                Text(
                  '${entry.value}',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
            onPressed: () => onToggle(entry.key),
          );
        }).toList(),
      ),
    );
  }
}

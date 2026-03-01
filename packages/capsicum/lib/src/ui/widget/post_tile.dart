import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';


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
                ],
              ),
            ),
          ],
        ),
      ),
    );
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
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (adapter is FavoriteSupport)
              ListTile(
                leading: const Icon(Icons.star_outline),
                title: const Text('お気に入り'),
                onTap: () {
                  Navigator.pop(context);
                  _runAction(
                    messenger,
                    () => (adapter as FavoriteSupport)
                        .favoritePost(targetPost.id),
                    'お気に入りに追加しました',
                  );
                },
              ),
            ListTile(
              leading: const Icon(Icons.repeat),
              title: Text(boostLabel),
              onTap: () {
                Navigator.pop(context);
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
                  Navigator.pop(context);
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

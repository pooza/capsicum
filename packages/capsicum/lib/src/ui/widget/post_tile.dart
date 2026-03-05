import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/timeline_provider.dart';
import 'emoji_picker.dart';


class PostTile extends ConsumerStatefulWidget {
  final Post post;
  final bool tappable;
  final VoidCallback? onActionCompleted;

  const PostTile({
    super.key,
    required this.post,
    this.tappable = true,
    this.onActionCompleted,
  });

  @override
  ConsumerState<PostTile> createState() => _PostTileState();
}

class _PostTileState extends ConsumerState<PostTile> {
  static const _maxLines = 8;
  static const _maxTags = 3;
  static final _urlRegex = RegExp(r'https?://[^\s<>\]）」』】]+');
  bool _expanded = false;
  bool _tagsExpanded = false;
  final List<GestureRecognizer> _recognizers = [];

  Post get post => widget.post;
  VoidCallback? get onActionCompleted => widget.onActionCompleted;

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  TextSpan _buildContentSpan(String text, TextStyle? baseStyle) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final matches = _urlRegex.allMatches(text).toList();
    if (matches.isEmpty) {
      return TextSpan(text: text, style: baseStyle);
    }

    final children = <TextSpan>[];
    var lastEnd = 0;

    for (final match in matches) {
      if (match.start > lastEnd) {
        children.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }
      final url = match.group(0)!;
      final uri = Uri.tryParse(url) ?? Uri.tryParse(Uri.encodeFull(url));
      final recognizer = TapGestureRecognizer()
        ..onTap = uri != null ? () => launchUrl(uri) : null;
      _recognizers.add(recognizer);
      final displayUrl =
          uri != null ? Uri.decodeFull(uri.toString()) : url;
      children.add(TextSpan(
        text: displayUrl,
        style: const TextStyle(color: Colors.blue),
        recognizer: recognizer,
      ));
      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      children.add(TextSpan(text: text.substring(lastEnd)));
    }

    return TextSpan(children: children, style: baseStyle);
  }

  @override
  Widget build(BuildContext context) {
    final displayPost = post.reblog ?? post;
    return InkWell(
      onTap: widget.tappable ? () => context.push('/post', extra: post) : null,
      onLongPress: () => _showActionMenu(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => context.push('/profile', extra: displayPost.author),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: displayPost.author.avatarUrl != null
                    ? Image.network(
                        displayPost.author.avatarUrl!,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                      )
                    : Container(
                        width: 40,
                        height: 40,
                        color: Theme.of(context).colorScheme.primaryContainer,
                        alignment: Alignment.center,
                        child: Text(
                          displayPost.author.username[0].toUpperCase(),
                        ),
                      ),
              ),
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          displayPost.author.displayName ??
                              displayPost.author.username,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        _scopeIcon(displayPost.scope),
                        size: 14,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _relativeTime(displayPost.postedAt),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  Text(
                    _handleText(displayPost.author),
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (displayPost.inReplyToId != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(
                            Icons.reply,
                            size: 14,
                            color: Theme.of(context).textTheme.bodySmall?.color,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '返信',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  Builder(builder: (_) {
                    final parsed = _parseContent(displayPost.content ?? '');
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final baseStyle = DefaultTextStyle.of(context).style;
                            final contentSpan = _buildContentSpan(
                              parsed.body,
                              baseStyle,
                            );
                            final textPainter = TextPainter(
                              text: contentSpan,
                              maxLines: _maxLines,
                              textDirection: TextDirection.ltr,
                            )..layout(maxWidth: constraints.maxWidth);
                            final overflows = textPainter.didExceedMaxLines;

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text.rich(
                                  contentSpan,
                                  maxLines: _expanded ? null : _maxLines,
                                  overflow: _expanded
                                      ? null
                                      : TextOverflow.ellipsis,
                                ),
                                if (overflows)
                                  GestureDetector(
                                    onTap: () =>
                                        setState(() => _expanded = !_expanded),
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        _expanded ? '折り畳む' : '続きを読む',
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                        if (parsed.trailingTags.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: [
                                ...(_tagsExpanded
                                        ? parsed.trailingTags
                                        : parsed.trailingTags.take(_maxTags))
                                    .map(
                                      (tag) => Chip(
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        visualDensity: VisualDensity.compact,
                                        label: Text(
                                          '#$tag',
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    ),
                                if (parsed.trailingTags.length > _maxTags)
                                  GestureDetector(
                                    onTap: () => setState(
                                        () => _tagsExpanded = !_tagsExpanded),
                                    child: Chip(
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      visualDensity: VisualDensity.compact,
                                      label: Text(
                                        _tagsExpanded
                                            ? '...'
                                            : '+${parsed.trailingTags.length - _maxTags}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    );
                  }),
                  if (displayPost.attachments.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _AttachmentThumbnails(
                        attachments: displayPost.attachments,
                      ),
                    ),
                  if (displayPost.reactions.isNotEmpty)
                    _ReactionChips(
                      post: displayPost,
                      onToggle: (emoji) => _toggleReaction(context, emoji),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleReaction(BuildContext context, String emoji) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! ReactionSupport) return;

    final reactionAdapter = adapter as ReactionSupport;
    final targetPost = post.reblog ?? post;
    final messenger = ScaffoldMessenger.of(context);

    if (targetPost.myReaction == emoji) {
      _runReactionAction(
        messenger,
        adapter,
        targetPost.id,
        () => reactionAdapter.removeReaction(targetPost.id, emoji),
        'リアクションを取り消しました',
      );
    } else {
      _runReactionAction(
        messenger,
        adapter,
        targetPost.id,
        () => reactionAdapter.addReaction(targetPost.id, emoji),
        'リアクションしました',
      );
    }
  }

  void _showActionMenu(BuildContext context) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    final currentUser = ref.read(currentAccountProvider)?.user;
    final targetPost = post.reblog ?? post;
    final isOwn = currentUser != null && targetPost.author.id == currentUser.id;
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
                  _showEmojiPicker(context);
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
            if (isOwn) ...[
              const Divider(),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('削除して再編集'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _confirmDeleteAndRedraft(context, targetPost);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  '削除',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _confirmDelete(context, targetPost);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, Post targetPost) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;
    final messenger = ScaffoldMessenger.of(context);

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('投稿を削除'),
        content: const Text('この投稿を削除しますか？この操作は取り消せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _runAction(
                messenger,
                () async {
                  await adapter.deletePost(targetPost.id);
                  ref.read(timelineProvider.notifier).removePost(targetPost.id);
                },
                '投稿を削除しました',
              );
            },
            child: Text(
              '削除',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteAndRedraft(BuildContext context, Post targetPost) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('削除して再編集'),
        content: const Text('投稿を削除し、内容を再編集します。この操作は取り消せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _runAction(
                messenger,
                () async {
                  await adapter.deletePost(targetPost.id);
                  ref.read(timelineProvider.notifier).removePost(targetPost.id);
                  if (mounted) {
                    router.push('/compose', extra: targetPost);
                  }
                },
                '投稿を削除しました',
              );
            },
            child: Text(
              '削除して再編集',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  void _showEmojiPicker(BuildContext context) {
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
      onActionCompleted?.call();
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
      onActionCompleted?.call();
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('エラー: $e')));
    }
  }

  String _handleText(User author) {
    final handle = '@${author.username}';
    if (author.host != null) {
      return '$handle@${author.host}';
    }
    return handle;
  }

  String _relativeTime(DateTime postedAt) {
    final diff = DateTime.now().toUtc().difference(postedAt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}秒前';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
    if (diff.inHours < 24) return '${diff.inHours}時間前';
    if (diff.inDays < 30) return '${diff.inDays}日前';
    final months = diff.inDays ~/ 30;
    if (months < 12) return '$monthsヶ月前';
    return '${diff.inDays ~/ 365}年前';
  }

  IconData _scopeIcon(PostScope scope) {
    switch (scope) {
      case PostScope.public:
        return Icons.public;
      case PostScope.unlisted:
        return Icons.lock_open;
      case PostScope.followersOnly:
        return Icons.lock;
      case PostScope.direct:
        return Icons.mail;
    }
  }

  /// Parse content into body text and trailing hashtags.
  /// Supports both Mastodon (HTML) and Misskey (MFM plain text).
  ({String body, List<String> trailingTags}) _parseContent(String content) {
    final isHtml = content.contains('<') && content.contains('>');

    if (isHtml) {
      return _parseHtmlContent(content);
    }
    return _parseMfmContent(content);
  }

  /// Mastodon HTML: trailing <p> block with hashtag links.
  ({String body, List<String> trailingTags}) _parseHtmlContent(String html) {
    var bodyHtml = html;
    final trailingTags = <String>[];

    final trailingTagBlock = RegExp(
      r'<p>\s*((<a[^>]*class="[^"]*hashtag[^"]*"[^>]*>.*?</a>\s*)+)</p>\s*$',
      caseSensitive: false,
    );
    final blockMatch = trailingTagBlock.firstMatch(bodyHtml);
    if (blockMatch != null) {
      final tagBlockHtml = blockMatch.group(1)!;
      final withoutTags = tagBlockHtml
          .replaceAll(RegExp(r'<a[^>]*class="[^"]*hashtag[^"]*"[^>]*>.*?</a>'), '')
          .trim();
      if (withoutTags.isEmpty) {
        final tagPattern = RegExp(r'#<span>([^<]+)</span>');
        for (final m in tagPattern.allMatches(tagBlockHtml)) {
          trailingTags.add(m.group(1)!);
        }
        bodyHtml = bodyHtml.substring(0, blockMatch.start).trimRight();
      }
    }

    return (body: _decodeHtml(bodyHtml), trailingTags: trailingTags);
  }

  /// Misskey MFM: trailing line of #tag after a blank line.
  ({String body, List<String> trailingTags}) _parseMfmContent(String text) {
    final trailingTags = <String>[];

    // Match a trailing line that contains only hashtags, preceded by a blank line.
    final trailingTagLine = RegExp(r'\n\n((?:#\S+\s*)+)$');
    final match = trailingTagLine.firstMatch(text);
    if (match != null) {
      final tagLine = match.group(1)!;
      final tagPattern = RegExp(r'#(\S+)');
      for (final m in tagPattern.allMatches(tagLine)) {
        trailingTags.add(m.group(1)!);
      }
      return (
        body: text.substring(0, match.start).trimRight(),
        trailingTags: trailingTags,
      );
    }

    return (body: text, trailingTags: trailingTags);
  }

  String _decodeHtml(String html) {
    var text = html
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</p>\s*<p>'), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '');
    text = text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAllMapped(
          RegExp(r'&#(\d+);'),
          (m) => String.fromCharCode(int.parse(m[1]!)),
        )
        .replaceAllMapped(
          RegExp(r'&#x([0-9a-fA-F]+);'),
          (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
        );
    return text;
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
          final isCustomEmoji =
              entry.key.startsWith(':') && entry.key.endsWith(':');
          final strippedKey = isCustomEmoji
              ? entry.key.substring(1, entry.key.length - 1)
              : entry.key;
          final nameOnly = strippedKey.replaceAll('@.', '');
          var emojiUrl = post.reactionEmojis[strippedKey] ??
              post.reactionEmojis[nameOnly];
          // Fallback: construct URL from Misskey emoji endpoint.
          if (emojiUrl == null && isCustomEmoji && post.author.host != null) {
            emojiUrl = 'https://${post.author.host}/emoji/$nameOnly.webp';
          }
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

class _AttachmentThumbnails extends StatelessWidget {
  final List<Attachment> attachments;

  const _AttachmentThumbnails({required this.attachments});

  @override
  Widget build(BuildContext context) {
    final images = attachments
        .where((a) =>
            a.type == AttachmentType.image || a.type == AttachmentType.gifv)
        .toList();
    if (images.isEmpty) return const SizedBox.shrink();

    if (images.length == 1) {
      final imageUrl = images.first.previewUrl ?? images.first.url;
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          imageUrl,
          height: 160,
          width: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(
            height: 160,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.broken_image_outlined),
          ),
        ),
      );
    }

    return SizedBox(
      height: 160,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: images.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (context, index) {
          final attachment = images[index];
          final imageUrl = attachment.previewUrl ?? attachment.url;
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              imageUrl,
              height: 160,
              width: 200,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                height: 160,
                width: 200,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
          );
        },
      ),
    );
  }
}

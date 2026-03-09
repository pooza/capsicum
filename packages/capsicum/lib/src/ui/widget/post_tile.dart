import 'dart:ui' show ImageFilter;

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../provider/timeline_provider.dart';
import 'emoji_picker.dart';
import 'emoji_text.dart';

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
  bool _expanded = false;
  bool _tagsExpanded = false;
  bool _cwExpanded = false;
  bool _filterExpanded = false;
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

  String? _resolveEmojiUrl(
    String shortcode,
    Map<String, String> emojis,
    String? fallbackHost,
  ) {
    final url = emojis[shortcode];
    if (url != null) return url;
    if (fallbackHost != null) {
      return 'https://$fallbackHost/emoji/$shortcode.webp';
    }
    return null;
  }

  TextSpan _buildContentSpan(
    String text,
    TextStyle? baseStyle,
    Map<String, String> emojis, {
    String? fallbackHost,
  }) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final pattern = RegExp(
      r'https?://[^\s<>\]）」』】]+|:([a-zA-Z0-9_-]+):|#([a-zA-Z0-9\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\uFF66-\uFF9F_]+)',
    );
    final matches = pattern.allMatches(text).toList();
    if (matches.isEmpty) {
      return TextSpan(text: text, style: baseStyle);
    }

    final children = <InlineSpan>[];
    var lastEnd = 0;

    for (final match in matches) {
      if (match.start > lastEnd) {
        children.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }

      if (match.group(1) != null) {
        // Emoji shortcode
        final shortcode = match.group(1)!;
        final emojiUrl = _resolveEmojiUrl(shortcode, emojis, fallbackHost);
        if (emojiUrl != null) {
          children.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Image.network(
                emojiUrl,
                width: 20,
                height: 20,
                errorBuilder: (_, _, _) =>
                    Text(':$shortcode:', style: const TextStyle(fontSize: 14)),
              ),
            ),
          );
        } else {
          children.add(TextSpan(text: match.group(0)!));
        }
      } else if (match.group(2) != null) {
        // Hashtag
        final tag = match.group(2)!;
        final recognizer = TapGestureRecognizer()
          ..onTap = () => context.push('/hashtag/$tag');
        _recognizers.add(recognizer);
        children.add(
          TextSpan(
            text: '#$tag',
            style: const TextStyle(color: Colors.blue),
            recognizer: recognizer,
          ),
        );
      } else {
        // URL
        final url = match.group(0)!;
        final uri = Uri.tryParse(url) ?? Uri.tryParse(Uri.encodeFull(url));
        final isSafeScheme =
            uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
        final recognizer = TapGestureRecognizer()
          ..onTap = isSafeScheme ? () => launchUrl(uri) : null;
        _recognizers.add(recognizer);
        final displayUrl = uri != null ? Uri.decodeFull(uri.toString()) : url;
        children.add(
          TextSpan(
            text: displayUrl,
            style: const TextStyle(color: Colors.blue),
            recognizer: recognizer,
          ),
        );
      }
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
    final isFilteredWarn = displayPost.filterAction == FilterAction.warn;

    // Show a compact placeholder for warn-filtered posts until expanded.
    if (isFilteredWarn && !_filterExpanded) {
      return InkWell(
        onTap: () => setState(() => _filterExpanded = true),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                Icons.filter_alt_outlined,
                size: 16,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'フィルタ: ${displayPost.filterTitle ?? "非表示"}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Text(
                '表示する',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      );
    }

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
                        child: EmojiText(
                          displayPost.author.displayName ??
                              displayPost.author.username,
                          emojis: displayPost.author.emojis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          fallbackHost: displayPost.emojiHost,
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
                  if (displayPost.spoilerText != null) ...[
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _cwExpanded = !_cwExpanded),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.warning_amber,
                                  size: 16,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: EmojiText(
                                    displayPost.spoilerText!,
                                    emojis: {
                                      ...displayPost.emojis,
                                      ...displayPost.author.emojis,
                                    },
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.bold),
                                    fallbackHost: displayPost.emojiHost,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _cwExpanded ? '閉じる' : '続きを表示',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (displayPost.spoilerText == null || _cwExpanded) ...[
                    Builder(
                      builder: (_) {
                        final parsed = _parseContent(displayPost.content ?? '');
                        final allEmojis = {
                          ...displayPost.emojis,
                          ...displayPost.author.emojis,
                        };
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final baseStyle = DefaultTextStyle.of(
                                  context,
                                ).style;
                                final contentSpan = _buildContentSpan(
                                  parsed.body,
                                  baseStyle,
                                  allEmojis,
                                  fallbackHost: displayPost.emojiHost,
                                );
                                // Use a plain TextSpan for overflow measurement
                                // because TextPainter cannot measure WidgetSpan.
                                final measureSpan = TextSpan(
                                  text: parsed.body,
                                  style: baseStyle,
                                );
                                final textPainter = TextPainter(
                                  text: measureSpan,
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
                                        onTap: () => setState(
                                          () => _expanded = !_expanded,
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            top: 4,
                                          ),
                                          child: Text(
                                            _expanded ? '折り畳む' : '続きを読む',
                                            style: TextStyle(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
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
                                            : parsed.trailingTags.take(
                                                _maxTags,
                                              ))
                                        .map(
                                          (tag) => ActionChip(
                                            materialTapTargetSize:
                                                MaterialTapTargetSize
                                                    .shrinkWrap,
                                            visualDensity:
                                                VisualDensity.compact,
                                            label: Text(
                                              '#$tag',
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                            onPressed: () => context.push(
                                              '/hashtag/$tag',
                                            ),
                                          ),
                                        ),
                                    if (parsed.trailingTags.length > _maxTags)
                                      GestureDetector(
                                        onTap: () => setState(
                                          () => _tagsExpanded = !_tagsExpanded,
                                        ),
                                        child: Chip(
                                          materialTapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            _tagsExpanded
                                                ? '...'
                                                : '+${parsed.trailingTags.length - _maxTags}',
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                    if (displayPost.attachments.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _AttachmentThumbnails(
                          attachments: displayPost.attachments,
                          sensitive: displayPost.sensitive,
                        ),
                      ),
                    if (displayPost.card != null &&
                        displayPost.attachments.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _PreviewCardWidget(card: displayPost.card!),
                      ),
                    if (displayPost.poll != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _PollWidget(
                          poll: displayPost.poll!,
                          postId: displayPost.id,
                          onActionCompleted: onActionCompleted,
                        ),
                      ),
                  ],
                  if (displayPost.replyCount > 0 ||
                      displayPost.reblogCount > 0 ||
                      displayPost.favouriteCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          if (displayPost.replyCount > 0) ...[
                            Icon(
                              Icons.reply,
                              size: 14,
                              color: Theme.of(
                                context,
                              ).textTheme.bodySmall?.color,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '${displayPost.replyCount}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(width: 12),
                          ],
                          if (displayPost.reblogCount > 0) ...[
                            Icon(
                              Icons.repeat,
                              size: 14,
                              color: Theme.of(
                                context,
                              ).textTheme.bodySmall?.color,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '${displayPost.reblogCount}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(width: 12),
                          ],
                          if (displayPost.favouriteCount > 0) ...[
                            Icon(
                              Icons.star_outline,
                              size: 14,
                              color: Theme.of(
                                context,
                              ).textTheme.bodySmall?.color,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '${displayPost.favouriteCount}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
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
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('リプライ'),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push(
                  '/compose',
                  extra: {'replyTo': targetPost},
                );
              },
            ),
            if (adapter is FavoriteSupport)
              ListTile(
                leading: const Icon(Icons.star_outline),
                title: const Text('お気に入り'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _runAction(
                    messenger,
                    () => (adapter as FavoriteSupport).favoritePost(
                      targetPost.id,
                    ),
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
                    () => (adapter as BookmarkSupport).bookmarkPost(
                      targetPost.id,
                    ),
                    '$bookmarkLabelに追加しました',
                  );
                },
              ),
            if (isOwn) ...[
              const Divider(),
              if (ref.read(currentMulukhiyaProvider) != null)
                ListTile(
                  leading: const Icon(Icons.sell_outlined),
                  title: const Text('削除してタグづけ'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showRetagSheet(context, targetPost);
                  },
                ),
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
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
        title: Text('${ref.read(postLabelProvider)}を削除'),
        content: Text('この${ref.read(postLabelProvider)}を削除しますか？この操作は取り消せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _runAction(messenger, () async {
                await adapter.deletePost(targetPost.id);
                ref.read(timelineProvider.notifier).removePost(targetPost.id);
              }, '${ref.read(postLabelProvider)}を削除しました');
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
        content: Text(
          '${ref.read(postLabelProvider)}を削除し、内容を再編集します。この操作は取り消せません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _runAction(messenger, () async {
                await adapter.deletePost(targetPost.id);
                ref.read(timelineProvider.notifier).removePost(targetPost.id);
                if (mounted) {
                  router.push('/compose', extra: {'redraft': targetPost});
                }
              }, '${ref.read(postLabelProvider)}を削除しました');
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
              () => (adapter as ReactionSupport).addReaction(
                targetPost.id,
                emoji,
              ),
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
      messenger.showSnackBar(const SnackBar(content: Text('操作に失敗しました')));
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
      messenger.showSnackBar(const SnackBar(content: Text('操作に失敗しました')));
    }
  }

  void _showRetagSheet(BuildContext context, Post targetPost) {
    final mulukhiya = ref.read(currentMulukhiyaProvider);
    if (mulukhiya == null) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    final parsed = _parseContent(targetPost.content ?? '');
    final messenger = ScaffoldMessenger.of(context);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RetagSheet(
        initialTags: parsed.trailingTags,
        mulukhiya: mulukhiya,
        postLabel: ref.read(postLabelProvider),
        onSubmit: (tags) async {
          try {
            // Build new body: original body + new footer tags.
            final tagLine = tags.map((t) => '#$t').join(' ');
            final newContent =
                parsed.body.trimRight() +
                (tagLine.isNotEmpty ? '\n\n$tagLine' : '');

            // Delete original, then repost with X-Mulukhiya to skip hooks.
            await adapter.deletePost(targetPost.id);
            await adapter.postStatus(
              PostDraft(
                content: newContent,
                scope: targetPost.scope,
                spoilerText: targetPost.spoilerText,
                skipMulukhiya: true,
              ),
            );
            ref.read(timelineProvider.notifier).removePost(targetPost.id);
            messenger.showSnackBar(const SnackBar(content: Text('タグを変更しました')));
          } catch (e) {
            messenger.showSnackBar(const SnackBar(content: Text('操作に失敗しました')));
          }
        },
      ),
    );
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
          .replaceAll(
            RegExp(r'<a[^>]*class="[^"]*hashtag[^"]*"[^>]*>.*?</a>'),
            '',
          )
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
          var emojiUrl =
              post.reactionEmojis[strippedKey] ?? post.reactionEmojis[nameOnly];
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
            backgroundColor: isMyReaction
                ? theme.colorScheme.primaryContainer
                : null,
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
                      errorBuilder: (_, _, _) =>
                          Text(entry.key, style: const TextStyle(fontSize: 14)),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      entry.key,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                Text('${entry.value}', style: theme.textTheme.labelSmall),
              ],
            ),
            onPressed: () => onToggle(entry.key),
          );
        }).toList(),
      ),
    );
  }
}

class _PollWidget extends ConsumerStatefulWidget {
  final Poll poll;
  final String postId;
  final VoidCallback? onActionCompleted;

  const _PollWidget({
    required this.poll,
    required this.postId,
    this.onActionCompleted,
  });

  @override
  ConsumerState<_PollWidget> createState() => _PollWidgetState();
}

class _PollWidgetState extends ConsumerState<_PollWidget> {
  late Set<int> _selected;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.poll.ownVotes.toSet();
  }

  bool get _hasVoted => widget.poll.voted;
  bool get _showResults => _hasVoted || widget.poll.expired;

  Future<void> _vote() async {
    if (_selected.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    try {
      final adapter = ref.read(currentAdapterProvider);
      if (adapter != null && adapter is PollSupport) {
        await (adapter as PollSupport).votePoll(widget.poll.id, _selected.toList());
        widget.onActionCompleted?.call();
      }
    } catch (e) {
      debugPrint('Poll vote error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('投票に失敗しました')),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _formatExpiry(Poll poll) {
    if (poll.expired) return '終了';
    final expiresAt = poll.expiresAt;
    if (expiresAt == null) return '';
    final diff = expiresAt.difference(DateTime.now());
    if (diff.isNegative) return '終了';
    if (diff.inDays > 0) return '残り${diff.inDays}日';
    if (diff.inHours > 0) return '残り${diff.inHours}時間';
    if (diff.inMinutes > 0) return '残り${diff.inMinutes}分';
    return '残りわずか';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final poll = widget.poll;
    final totalVotes =
        poll.options.fold<int>(0, (sum, o) => sum + o.votesCount);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < poll.options.length; i++)
          _buildOption(context, theme, poll.options[i], i, totalVotes),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              '$totalVotes票',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (_formatExpiry(poll).isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                _formatExpiry(poll),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (!_showResults && _selected.isNotEmpty) ...[
              const Spacer(),
              SizedBox(
                height: 28,
                child: FilledButton(
                  onPressed: _submitting ? null : _vote,
                  child: _submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('投票'),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildOption(
    BuildContext context,
    ThemeData theme,
    PollOption option,
    int index,
    int totalVotes,
  ) {
    final fraction = totalVotes > 0 ? option.votesCount / totalVotes : 0.0;
    final percentage = (fraction * 100).round();
    final isOwnVote = widget.poll.ownVotes.contains(index);

    if (_showResults) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (isOwnVote)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.check_circle,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                Expanded(
                  child: Text(
                    option.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isOwnVote ? FontWeight.bold : null,
                    ),
                  ),
                ),
                Text(
                  '$percentage%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 6,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          ],
        ),
      );
    }

    // Voting mode
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: () {
          setState(() {
            if (widget.poll.multiple) {
              if (_selected.contains(index)) {
                _selected.remove(index);
              } else {
                _selected.add(index);
              }
            } else {
              _selected = {index};
            }
          });
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(
              color: _selected.contains(index)
                  ? theme.colorScheme.primary
                  : theme.dividerColor,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                widget.poll.multiple
                    ? (_selected.contains(index)
                        ? Icons.check_box
                        : Icons.check_box_outline_blank)
                    : (_selected.contains(index)
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked),
                size: 18,
                color: _selected.contains(index)
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(option.title)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewCardWidget extends StatelessWidget {
  final PreviewCard card;

  const _PreviewCardWidget({required this.card});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () {
        final uri = Uri.tryParse(card.url);
        if (uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https')) {
          launchUrl(uri);
        }
      },
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (card.imageUrl != null)
              Image.network(
                card.imageUrl!,
                width: double.infinity,
                height: 160,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (card.description != null &&
                      card.description!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      card.description!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentThumbnails extends StatefulWidget {
  final List<Attachment> attachments;
  final bool sensitive;

  const _AttachmentThumbnails({
    required this.attachments,
    this.sensitive = false,
  });

  @override
  State<_AttachmentThumbnails> createState() => _AttachmentThumbnailsState();
}

class _AttachmentThumbnailsState extends State<_AttachmentThumbnails> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final images = widget.attachments
        .where(
          (a) =>
              a.type == AttachmentType.image ||
              a.type == AttachmentType.gifv ||
              a.type == AttachmentType.video,
        )
        .toList();
    final audios = widget.attachments
        .where((a) => a.type == AttachmentType.audio)
        .toList();
    if (images.isEmpty && audios.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (images.isNotEmpty) _buildImageGrid(context, images),
        for (final audio in audios) _buildAudioCard(context, audio, audios),
      ],
    );
  }

  Widget _buildImageGrid(BuildContext context, List<Attachment> images) {
    if (images.length == 1) {
      return SizedBox(
        height: 200,
        child: _buildThumbnail(context, images.first, 0, images),
      );
    }

    if (images.length == 2) {
      return SizedBox(
        height: 160,
        child: Row(
          children: [
            Expanded(child: _buildThumbnail(context, images[0], 0, images)),
            const SizedBox(width: 4),
            Expanded(child: _buildThumbnail(context, images[1], 1, images)),
          ],
        ),
      );
    }

    // 3+ images: 2x2 grid (with +N overlay if more than 4)
    final extraCount = images.length - 4;
    return SizedBox(
      height: 320,
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildThumbnail(context, images[0], 0, images)),
                const SizedBox(width: 4),
                Expanded(child: _buildThumbnail(context, images[1], 1, images)),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildThumbnail(context, images[2], 2, images)),
                if (images.length >= 4) ...[
                  const SizedBox(width: 4),
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _buildThumbnail(context, images[3], 3, images),
                        if (extraCount > 0)
                          GestureDetector(
                            onTap: () => context.push(
                              '/media',
                              extra: {'attachments': images, 'initialIndex': 3},
                            ),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                '+$extraCount',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThumbnail(
    BuildContext context,
    Attachment attachment,
    int index,
    List<Attachment> images,
  ) {
    final imageUrl = attachment.previewUrl ?? attachment.url;
    final isSensitive = widget.sensitive && !_revealed;

    return GestureDetector(
      onTap: () {
        if (isSensitive) {
          setState(() => _revealed = true);
        } else {
          context.push(
            '/media',
            extra: {'attachments': images, 'initialIndex': index},
          );
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ImageFiltered(
              imageFilter: isSensitive
                  ? ImageFilter.blur(sigmaX: 30, sigmaY: 30)
                  : ImageFilter.matrix(Matrix4.identity().storage),
              child: Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.broken_image_outlined),
                ),
              ),
            ),
            if (isSensitive)
              Positioned.fill(
                child: Container(
                  color: Colors.black45,
                  alignment: Alignment.center,
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.visibility_off,
                        color: Colors.white70,
                        size: 28,
                      ),
                      SizedBox(height: 4),
                      Text(
                        '閲覧注意',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            if (!isSensitive && attachment.type == AttachmentType.video)
              const Center(
                child: Icon(
                  Icons.play_circle_outline,
                  color: Colors.white70,
                  size: 48,
                ),
              ),
            if (!isSensitive && attachment.description != null)
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'ALT',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioCard(
    BuildContext context,
    Attachment audio,
    List<Attachment> allAudios,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: GestureDetector(
        onTap: () => context.push(
          '/media',
          extra: {
            'attachments': [audio],
            'initialIndex': 0,
          },
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                Icons.music_note,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  audio.description ?? '音声',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              Icon(
                Icons.play_circle_outline,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RetagSheet extends StatefulWidget {
  final List<String> initialTags;
  final MulukhiyaService mulukhiya;
  final String postLabel;
  final Future<void> Function(List<String> tags) onSubmit;

  const _RetagSheet({
    required this.initialTags,
    required this.mulukhiya,
    required this.postLabel,
    required this.onSubmit,
  });

  @override
  State<_RetagSheet> createState() => _RetagSheetState();
}

class _RetagSheetState extends State<_RetagSheet> {
  late final List<String> _tags;
  final _controller = TextEditingController();
  bool _submitting = false;
  List<String> _defaultTags = [];

  @override
  void initState() {
    super.initState();
    _tags = List.of(widget.initialTags);
    _loadDefaultTags();
  }

  Future<void> _loadDefaultTags() async {
    final tags = await widget.mulukhiya.getDefaultHashtags();
    if (mounted) setState(() => _defaultTags = tags);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _addTag() {
    final text = _controller.text.trim().replaceAll('#', '');
    if (text.isEmpty || _tags.contains(text)) return;
    setState(() => _tags.add(text));
    _controller.clear();
  }

  bool _isDefaultTag(String tag) =>
      _defaultTags.any((d) => d.toLowerCase() == tag.toLowerCase());

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      expand: false,
      builder: (context, scrollController) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('削除してタグづけ', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '元の${widget.postLabel}を削除し、指定したタグで再${widget.postLabel}します。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollController,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _tags.map((tag) {
                    final locked = _isDefaultTag(tag);
                    return Chip(
                      label: Text('#$tag'),
                      onDeleted: locked
                          ? null
                          : () => setState(() => _tags.remove(tag)),
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'タグを追加',
                      prefixText: '#',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _addTag(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(onPressed: _addTag, icon: const Icon(Icons.add)),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submitting
                    ? null
                    : () async {
                        setState(() => _submitting = true);
                        await widget.onSubmit(_tags);
                        if (context.mounted) Navigator.pop(context);
                      },
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text('タグを変更して再${widget.postLabel}'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

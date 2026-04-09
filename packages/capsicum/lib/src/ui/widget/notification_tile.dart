import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart' hide Notification;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../provider/timeline_provider.dart';
import '../../service/tco_resolver.dart';
import '../../url_helper.dart';
import 'content_parser.dart';
import 'emoji_picker.dart';
import 'emoji_text.dart';
import 'user_avatar.dart';

class NotificationTile extends ConsumerStatefulWidget {
  final Notification notification;
  final String postLabel;
  final String reblogLabel;

  const NotificationTile({
    super.key,
    required this.notification,
    this.postLabel = '投稿',
    this.reblogLabel = 'ブースト',
  });

  @override
  ConsumerState<NotificationTile> createState() => _NotificationTileState();
}

class _NotificationTileState extends ConsumerState<NotificationTile> {
  ContentRenderer? _contentRenderer;

  Notification get notification => widget.notification;

  static final _tcoPattern = RegExp(r'https?://t\.co/\S+');

  @override
  void initState() {
    super.initState();
    _resolveTcoUrls();
  }

  void _resolveTcoUrls() {
    final content = notification.post?.content;
    if (content == null) return;
    for (final match in _tcoPattern.allMatches(content)) {
      final url = match.group(0)!;
      if (TcoResolver.getCached(url) != null) continue;
      TcoResolver.resolve(url).then((resolved) {
        if (resolved != null && mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _contentRenderer?.dispose();
    super.dispose();
  }

  TextSpan _renderContent(String content, TextStyle baseStyle) {
    _contentRenderer?.dispose();
    final post = notification.post;
    final allEmojis = {...?post?.emojis, ...?post?.author.emojis};
    final host = post?.author.host;
    _contentRenderer = ContentRenderer(
      baseStyle: baseStyle,
      resolveEmoji: (shortcode) {
        final url = allEmojis[shortcode];
        if (url != null) return url;
        if (host != null) return 'https://$host/emoji/$shortcode.webp';
        return null;
      },
      resolveUrl: (url) =>
          TcoResolver.isTcoUrl(url) ? TcoResolver.getCached(url) : null,
      onLinkTap: (url) {
        final uri = Uri.tryParse(url);
        if (uri != null) launchUrlSafely(uri);
      },
      onHashtagTap: (tag) => context.push('/hashtag/$tag'),
      emojiSize: ref.watch(emojiSizeProvider),
    );
    final isHtml = content.contains('<p>') || content.contains('<br');
    return isHtml
        ? _contentRenderer!.renderHtml(content)
        : _contentRenderer!.renderMfm(content);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, label) = _iconAndLabel;
    final content = notification.post?.content;

    return InkWell(
      onTap: notification.post != null
          ? () => context.push('/post', extra: notification.post!)
          : null,
      onLongPress: notification.post != null
          ? () => _showActionMenu(context)
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (notification.type == NotificationType.reaction &&
                notification.reaction != null)
              SizedBox(
                width: 20,
                height: 20,
                child: Center(
                  child: _buildReactionEmoji(notification.reaction!),
                ),
              )
            else
              Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(context, label),
                  if (content != null) ...[
                    const SizedBox(height: 4),
                    Text.rich(
                      _renderContent(
                        content,
                        theme.textTheme.bodyMedium ?? const TextStyle(),
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

  void _showActionMenu(BuildContext context) {
    final post = notification.post;
    if (post == null) return;

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    final targetPost = post.reblog ?? post;
    final messenger = ScaffoldMessenger.of(context);
    final boostLabel = ref.read(reblogLabelProvider);
    final bookmarkLabel = adapter is ReactionSupport ? 'お気に入り' : 'ブックマーク';

    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('リプライ'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  context.push('/compose', extra: {'replyTo': targetPost});
                },
              ),
              if (targetPost.quotable)
                ListTile(
                  leading: const Icon(Icons.format_quote),
                  title: const Text('引用'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    context.push('/compose', extra: {'quoteTo': targetPost});
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
              if (targetPost.scope == PostScope.public ||
                  targetPost.scope == PostScope.unlisted)
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
              if (targetPost.url != null)
                ListTile(
                  leading: const Icon(Icons.link),
                  title: const Text('URL をコピー'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Clipboard.setData(ClipboardData(text: targetPost.url!));
                    messenger.showSnackBar(
                      const SnackBar(content: Text('URL をコピーしました')),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _runAction(
    ScaffoldMessengerState messenger,
    Future<Post> Function() action,
    String successMessage,
  ) async {
    try {
      final updated = await action();
      ref.read(timelineProvider.notifier).updatePost(updated);
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (e) {
      messenger.showSnackBar(const SnackBar(content: Text('操作に失敗しました')));
    }
  }

  void _showEmojiPicker(BuildContext context) {
    final account = ref.read(currentAccountProvider);
    final adapter = account?.adapter;
    if (adapter is! ReactionSupport) return;

    final post = notification.post;
    if (post == null) return;
    final targetPost = post.reblog ?? post;
    final messenger = ScaffoldMessenger.of(context);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.5,
        child: EmojiPicker(
          adapter: adapter as BackendAdapter,
          host: account!.key.host,
          mulukhiya: account.mulukhiya,
          accessToken: account.userSecret.accessToken,
          forReaction: true,
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
      final updated = await adapter.getPostById(postId);
      ref.read(timelineProvider.notifier).updatePost(updated);
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (e) {
      messenger.showSnackBar(const SnackBar(content: Text('操作に失敗しました')));
    }
  }

  Widget _buildHeader(BuildContext context, String label) {
    final theme = Theme.of(context);
    final user = notification.user;

    if (user == null) {
      return Row(
        children: [
          Expanded(
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Text(
            _formatTime(notification.createdAt),
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    }

    final displayName = user.displayName ?? user.username;

    return Row(
      children: [
        GestureDetector(
          onTap: () => context.push('/profile', extra: user),
          child: UserAvatar(user: user, size: 24, borderRadius: 4),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: EmojiText(
                  displayName,
                  emojis: user.emojis,
                  fallbackHost: user.host,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(' が$label', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _formatTime(notification.createdAt),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  String _formatTime(DateTime time) {
    if (ref.watch(absoluteTimeProvider)) {
      final local = time.toLocal();
      return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
          '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    final diff = DateTime.now().toUtc().difference(time);
    if (diff.inSeconds < 60) return '${diff.inSeconds}秒前';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
    if (diff.inHours < 24) return '${diff.inHours}時間前';
    if (diff.inDays < 30) return '${diff.inDays}日前';
    final months = diff.inDays ~/ 30;
    if (months < 12) return '$monthsヶ月前';
    return '${diff.inDays ~/ 365}年前';
  }

  (IconData, String) get _iconAndLabel => switch (notification.type) {
    NotificationType.mention => (Icons.alternate_email, 'メンション'),
    NotificationType.reblog => (Icons.repeat, widget.reblogLabel),
    NotificationType.favourite => (Icons.star, 'お気に入り'),
    NotificationType.follow => (Icons.person_add, 'フォロー'),
    NotificationType.followRequest => (Icons.person_add_alt, 'フォローリクエスト'),
    NotificationType.reaction => (Icons.emoji_emotions, 'リアクション'),
    NotificationType.poll => (Icons.poll, 'アンケート終了'),
    NotificationType.update => (Icons.edit, '${widget.postLabel}を編集'),
    NotificationType.other => (Icons.notifications, '通知'),
  };

  Widget _buildReactionEmoji(String reaction) {
    final url = _resolveReactionUrl(reaction);
    if (url != null) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 18, maxWidth: 54),
        child: Image.network(
          url,
          height: 18,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) =>
              Text(reaction, style: const TextStyle(fontSize: 14)),
        ),
      );
    }
    return Text(reaction, style: const TextStyle(fontSize: 16));
  }

  /// Resolve reaction key to an emoji image URL (custom emoji) or null (unicode).
  String? _resolveReactionUrl(String reaction) {
    final isCustom = reaction.startsWith(':') && reaction.endsWith(':');
    if (!isCustom) return null;
    final stripped = reaction.substring(1, reaction.length - 1);
    final nameOnly = stripped.contains('@')
        ? stripped.substring(0, stripped.indexOf('@'))
        : stripped;
    // Check reactionEmojis from the post first.
    final post = notification.post;
    final url =
        post?.reactionEmojis[stripped] ?? post?.reactionEmojis[nameOnly];
    if (url != null) return url;
    // Fallback: construct URL from emoji host.
    final atIndex = stripped.indexOf('@');
    final hostPart = atIndex >= 0 ? stripped.substring(atIndex + 1) : null;
    final isLocal = hostPart == null || hostPart == '.' || hostPart.isEmpty;
    final emojiHost = isLocal
        ? (post?.emojiHost ?? post?.author.host)
        : hostPart;
    if (emojiHost != null) {
      return 'https://$emojiHost/emoji/$nameOnly.webp';
    }
    return null;
  }
}

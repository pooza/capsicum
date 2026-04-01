import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart' hide Notification;
import 'package:go_router/go_router.dart';

import '../../service/tco_resolver.dart';
import '../../url_helper.dart';
import 'content_parser.dart';
import 'emoji_text.dart';
import 'user_avatar.dart';

class NotificationTile extends StatefulWidget {
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
  State<NotificationTile> createState() => _NotificationTileState();
}

class _NotificationTileState extends State<NotificationTile> {
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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

  Widget _buildHeader(BuildContext context, String label) {
    final theme = Theme.of(context);
    final user = notification.user;

    if (user == null) {
      return Text(label, style: theme.textTheme.bodySmall);
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
              if (notification.type == NotificationType.reaction &&
                  notification.reaction != null) ...[
                const SizedBox(width: 4),
                _buildReactionEmoji(notification.reaction!),
              ],
            ],
          ),
        ),
      ],
    );
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

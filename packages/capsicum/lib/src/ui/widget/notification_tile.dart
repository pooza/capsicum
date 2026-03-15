import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart' hide Notification;
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import 'content_parser.dart';
import 'emoji_text.dart';

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
      onLinkTap: (url) {
        final uri = Uri.tryParse(url);
        if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
          launchUrl(uri);
        }
      },
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
    final displayName = user?.displayName ?? user?.username ?? '';

    return Row(
      children: [
        if (user != null) ...[
          GestureDetector(
            onTap: () => context.push('/profile', extra: user),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: user.avatarUrl != null
                  ? Image.network(
                      user.avatarUrl!,
                      width: 24,
                      height: 24,
                      fit: BoxFit.cover,
                    )
                  : Container(
                      width: 24,
                      height: 24,
                      color: theme.colorScheme.primaryContainer,
                      alignment: Alignment.center,
                      child: Text(
                        user.username[0].toUpperCase(),
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: EmojiText(
                  displayName,
                  emojis: user?.emojis ?? const {},
                  fallbackHost: user?.host,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(' が$label', style: theme.textTheme.bodySmall),
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
}

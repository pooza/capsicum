import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart' hide Notification;
import 'package:go_router/go_router.dart';

import 'emoji_text.dart';

class NotificationTile extends StatelessWidget {
  final Notification notification;
  final String postLabel;

  const NotificationTile({
    super.key,
    required this.notification,
    this.postLabel = '投稿',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, label) = _iconAndLabel;

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
                  if (notification.post?.content != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _stripHtml(notification.post!.content!),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
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
          ClipRRect(
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
                    child: Text(user.username[0].toUpperCase(),
                        style: const TextStyle(fontSize: 10)),
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
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                ' が$label',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  (IconData, String) get _iconAndLabel => switch (notification.type) {
    NotificationType.mention => (Icons.alternate_email, 'メンション'),
    NotificationType.reblog => (Icons.repeat, 'ブースト'),
    NotificationType.favourite => (Icons.star, 'お気に入り'),
    NotificationType.follow => (Icons.person_add, 'フォロー'),
    NotificationType.followRequest => (Icons.person_add_alt, 'フォローリクエスト'),
    NotificationType.reaction => (Icons.emoji_emotions, 'リアクション'),
    NotificationType.poll => (Icons.poll, 'アンケート終了'),
    NotificationType.update => (Icons.edit, '$postLabelを編集'),
    NotificationType.other => (Icons.notifications, '通知'),
  };

  String _stripHtml(String html) {
    var text = html
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</p>\s*<p>'), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '');
    // Decode HTML entities.
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

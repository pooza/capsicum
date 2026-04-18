import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart' hide Notification;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../provider/unified_notification_provider.dart';
import '../widget/content_parser.dart';
import '../widget/emoji_text.dart';
import '../widget/user_avatar.dart';

class UnifiedNotificationScreen extends ConsumerWidget {
  const UnifiedNotificationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(unifiedNotificationProvider);
    final reblogLabel = ref.watch(reblogLabelProvider);
    final postLabel = ref.watch(postLabelProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('すべての通知'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: state.when(
        data: (data) {
          if (data.items.isEmpty && data.failedAccounts.isEmpty) {
            return const Center(child: Text('通知はありません'));
          }
          return RefreshIndicator(
            onRefresh: () => ref.refresh(unifiedNotificationProvider.future),
            child: ListView.separated(
              itemCount:
                  data.items.length + (data.failedAccounts.isEmpty ? 0 : 1),
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                if (index < data.items.length) {
                  return _UnifiedNotificationTile(
                    item: data.items[index],
                    reblogLabel: reblogLabel,
                    postLabel: postLabel,
                  );
                }
                return _FailedAccountsFooter(accounts: data.failedAccounts);
              },
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('通知の読み込みに失敗しました\n$error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref.invalidate(unifiedNotificationProvider),
                  child: const Text('再試行'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UnifiedNotificationTile extends ConsumerWidget {
  final UnifiedNotification item;
  final String reblogLabel;
  final String postLabel;

  const _UnifiedNotificationTile({
    required this.item,
    required this.reblogLabel,
    required this.postLabel,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notification = item.notification;
    final account = item.account;
    final user = notification.user;
    final post = notification.post;
    final (icon, label) = _iconAndLabel(notification.type);
    final useAbsoluteTime = ref.watch(absoluteTimeProvider);

    return InkWell(
      onTap: () => _openInOwningAccount(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: Center(
                child:
                    notification.type == NotificationType.reaction &&
                        notification.reaction != null
                    ? _buildReactionEmoji(notification.reaction!)
                    : Icon(icon, size: 20, color: theme.colorScheme.primary),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _accountBadge(context, account),
                  const SizedBox(height: 4),
                  _header(
                    context,
                    user,
                    label,
                    notification.createdAt,
                    useAbsoluteTime,
                  ),
                  if (post?.content != null && post!.content!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      stripHtml(post.content!),
                      maxLines: 2,
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

  Widget _accountBadge(BuildContext context, Account account) {
    final theme = Theme.of(context);
    final displayName = account.user.displayName;
    final acct = '@${account.user.username}@${account.key.host}';
    final hasDisplayName = displayName != null && displayName.trim().isNotEmpty;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Row(
      children: [
        UserAvatar(
          user: account.user,
          size: 16,
          compact: true,
          borderRadius: 2,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: hasDisplayName
              ? EmojiText(
                  displayName,
                  emojis: account.user.emojis,
                  fallbackHost: account.user.host,
                  style: labelStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : Text(
                  acct,
                  style: labelStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
        ),
      ],
    );
  }

  Widget _header(
    BuildContext context,
    User? user,
    String label,
    DateTime createdAt,
    bool useAbsoluteTime,
  ) {
    final theme = Theme.of(context);
    if (user == null) {
      return Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
          Text(
            _formatTime(createdAt, useAbsoluteTime),
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    }
    final displayName = user.displayName ?? user.username;
    return Row(
      children: [
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
          _formatTime(createdAt, useAbsoluteTime),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

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

  String? _resolveReactionUrl(String reaction) {
    final isCustom = reaction.startsWith(':') && reaction.endsWith(':');
    if (!isCustom) return null;
    final stripped = reaction.substring(1, reaction.length - 1);
    final nameOnly = stripped.contains('@')
        ? stripped.substring(0, stripped.indexOf('@'))
        : stripped;
    final post = item.notification.post;
    final url =
        post?.reactionEmojis[stripped] ?? post?.reactionEmojis[nameOnly];
    if (url != null) return url;
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

  void _openInOwningAccount(BuildContext context, WidgetRef ref) {
    final post = item.notification.post;
    final user = item.notification.user;
    final manager = ref.read(accountManagerProvider.notifier);
    final current = ref.read(currentAccountProvider);
    if (current?.key != item.account.key) {
      manager.switchAccount(item.account);
    }
    if (post != null) {
      context.push('/post', extra: post);
    } else if (user != null) {
      context.push('/profile', extra: user);
    }
  }

  (IconData, String) _iconAndLabel(NotificationType type) => switch (type) {
    NotificationType.mention => (Icons.alternate_email, 'メンション'),
    NotificationType.reblog => (Icons.repeat, reblogLabel),
    NotificationType.favourite => (Icons.star, 'お気に入り'),
    NotificationType.follow => (Icons.person_add, 'フォロー'),
    NotificationType.followRequest => (Icons.person_add_alt, 'フォローリクエスト'),
    NotificationType.reaction => (Icons.emoji_emotions, 'リアクション'),
    NotificationType.poll => (Icons.poll, 'アンケート終了'),
    NotificationType.update => (Icons.edit, '$postLabelを編集'),
    NotificationType.login => (Icons.login, 'ログイン'),
    NotificationType.createToken => (Icons.key, 'アクセストークン作成'),
    NotificationType.other => (Icons.notifications, '通知'),
  };

  String _formatTime(DateTime time, bool useAbsoluteTime) {
    if (useAbsoluteTime) {
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
}

class _FailedAccountsFooter extends StatelessWidget {
  final List<Account> accounts;

  const _FailedAccountsFooter({required this.accounts});

  @override
  Widget build(BuildContext context) {
    if (accounts.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final names = accounts
        .map((a) => '@${a.user.username}@${a.key.host}')
        .join(', ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(
        '以下のアカウントは取得に失敗しました: $names',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }
}

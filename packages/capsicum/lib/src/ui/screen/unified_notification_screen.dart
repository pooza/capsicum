import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart' hide Notification;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../provider/unified_notification_provider.dart';
import '../../service/tco_resolver.dart';
import '../util/fediverse_link.dart';
import '../util/hashtag_actions.dart';
import '../util/notification_type_display.dart';
import '../util/relative_time.dart';
import '../widget/content_parser.dart';
import '../widget/emoji_text.dart';
import '../widget/server_badge.dart';
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
          // 取得状況バナー（#862 B）を常に最上部に置き、逐次描画（#862 A）で
          // 差し込まれる通知リストをその下に並べる。バナーは pending / failed が
          // 無くなれば自動的に畳まれる。
          final banner = _UnifiedStatusBanner(state: data);
          final Widget listArea;
          if (data.isComplete &&
              data.items.isEmpty &&
              data.failedAccounts.isEmpty) {
            listArea = const Center(child: Text('通知はありません'));
          } else {
            listArea = ListView.separated(
              // 件数が少ない / 空でも pull-to-refresh できるようにする。
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: data.items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) => _UnifiedNotificationTile(
                item: data.items[index],
                reblogLabel: reblogLabel,
                postLabel: postLabel,
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () => ref.refresh(unifiedNotificationProvider.future),
            child: Column(
              children: [
                banner,
                Expanded(child: listArea),
              ],
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

class _UnifiedNotificationTile extends ConsumerStatefulWidget {
  final UnifiedNotification item;
  final String reblogLabel;
  final String postLabel;

  const _UnifiedNotificationTile({
    required this.item,
    required this.reblogLabel,
    required this.postLabel,
  });

  @override
  ConsumerState<_UnifiedNotificationTile> createState() =>
      _UnifiedNotificationTileState();
}

class _UnifiedNotificationTileState
    extends ConsumerState<_UnifiedNotificationTile> {
  ContentRenderer? _contentRenderer;

  UnifiedNotification get item => widget.item;

  @override
  void dispose() {
    _contentRenderer?.dispose();
    super.dispose();
  }

  /// 通知画面 (NotificationTile) と同じロジックで本文をレンダリング。
  /// カスタム絵文字・MFM / HTML の両対応、`@cat` の場合 nyaize を適用する。
  TextSpan _renderContent(String content, TextStyle baseStyle) {
    _contentRenderer?.dispose();
    final post = item.notification.post;
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
      onLinkTap: (url) => openFediverseLink(context, ref, url),
      onHashtagTap: (tag) => showHashtagActionMenu(context, tag),
      emojiSize: ref.watch(emojiSizeProvider),
      animateMfm: ref.watch(mfmAnimationEnabledProvider),
      applyNyaize: post?.author.isCat ?? false,
    );
    final isHtml = post?.isHtml ?? false;
    return isHtml
        ? _contentRenderer!.renderHtml(content)
        : _contentRenderer!.renderMfm(content);
  }

  @override
  Widget build(BuildContext context) {
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
                    Text.rich(
                      _renderContent(
                        post.content!,
                        theme.textTheme.bodyMedium ?? const TextStyle(),
                      ),
                      maxLines: 2,
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

  Widget _accountBadge(BuildContext context, Account account) {
    final theme = Theme.of(context);
    final displayName = account.user.displayName;
    final acct = '@${account.user.username}@${account.key.host}';
    final hasDisplayName = displayName != null && displayName.trim().isNotEmpty;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final themeColors = ref.watch(hostThemeColorProvider);
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
        const SizedBox(width: 6),
        // 通知宛先アカウントのサーバーを示すインスタンスティッカー。
        ServerBadge.fromHost(account.key.host, themeColors: themeColors),
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
          TimestampText(
            createdAt,
            absolute: useAbsoluteTime,
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
        TimestampText(
          createdAt,
          absolute: useAbsoluteTime,
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

  (IconData, String) _iconAndLabel(NotificationType type) {
    final display = notificationTypeDisplay(
      type,
      reblogLabel: widget.reblogLabel,
      postLabel: widget.postLabel,
    );
    return (display.icon, display.label);
  }
}

/// 「すべての通知」の取得状況バナー (#862 B)。リスト最上部に置き、逐次描画
/// （#862 A）で「まだ来ていないサーバー」「取得に失敗したサーバー」を可視化する。
/// 従来は失敗表示がリスト最下部の footer にあり、最大 100 件スクロールしないと
/// 見えなかった。pending も failed も無ければ何も描画しない（畳まれる）。
class _UnifiedStatusBanner extends StatelessWidget {
  final UnifiedNotificationState state;

  const _UnifiedStatusBanner({required this.state});

  static String _acct(Account a) => '@${a.user.username}@${a.key.host}';

  @override
  Widget build(BuildContext context) {
    final hasPending = state.pendingAccounts.isNotEmpty;
    final hasFailed = state.failedAccounts.isNotEmpty;
    if (!hasPending && !hasFailed) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final rows = <Widget>[];

    if (hasPending) {
      final names = state.pendingAccounts.map(_acct).join(', ');
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${state.totalAccounts} 件中 ${state.settledCount} 件を取得しました'
                ' · $names を待っています',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    if (hasFailed) {
      if (hasPending) rows.add(const SizedBox(height: 6));
      final names = state.failedAccounts.map(_acct).join(', ');
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$names は取得に失敗しました',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }
}

import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart' hide Notification;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../service/tco_resolver.dart';
import '../util/fediverse_link.dart';
import '../util/hashtag_actions.dart';
import '../util/notification_type_display.dart';
import '../util/post_actions.dart';
import '../util/visible_timeline.dart';
import '../util/relative_time.dart';
import '../util/post_scope_display.dart';
import 'content_parser.dart';
import 'cross_account_boost.dart';
import 'emoji_action_sheet.dart';
import 'reaction_picker_sheet.dart';
import 'emoji_text.dart';
import 'post_touch_action_row.dart';
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
      onLinkTap: (url) => openFediverseLink(context, ref, url),
      onHashtagTap: (tag) => showHashtagActionMenu(context, tag),
      onEmojiTap: post != null
          ? (shortcode, emojiUrl) =>
                _showEmojiActionMenu(context, post, shortcode, emojiUrl)
          : null,
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
    final (icon, label) = _iconAndLabel;
    final content = notification.post?.content;

    return InkWell(
      onTap: notification.post != null
          ? () => context.push('/post', extra: notification.post!)
          // Collections 通知 (#741): post を持たないため、タップで対象コレクション
          // の詳細（#742）を開く。
          : notification.collection != null
          ? () =>
                context.push('/collection', extra: notification.collection!.id)
          // 実績解除通知 (#918): post を持たないため、タップで実績一覧を開く。
          : notification.type == NotificationType.achievementEarned
          ? () => context.push('/achievements')
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
                  // Collections 通知 (#741): post を持たないため、対象コレクション名を
                  // 表示する。タイル全体のタップで詳細（#742）へ遷移する。
                  if (notification.collection != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      notification.collection!.name,
                      style: theme.textTheme.bodyMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  // 実績解除通知 (#918): 解除した実績名（見出しのみ・説明文は出さない）を
                  // 表示する。タイル全体のタップで実績一覧へ遷移する。
                  if (notification.type ==
                      NotificationType.achievementEarned) ...[
                    const SizedBox(height: 4),
                    Text(
                      _achievementLabel(notification.achievement),
                      style: theme.textTheme.bodyMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (notification.post != null)
                    PostTouchActionRow(
                      targetPost:
                          notification.post!.reblog ?? notification.post!,
                      outerPost: notification.post!,
                    ),
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
                  subtitle: boostableScopes(targetPost.scope).isNotEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Wrap(
                            spacing: 8,
                            children: boostableScopes(targetPost.scope).map((
                              scope,
                            ) {
                              final display = postScopeDisplay(scope, adapter);
                              return ActionChip(
                                avatar: Icon(display.icon, size: 16),
                                label: Text(display.label),
                                onPressed: () {
                                  Navigator.pop(sheetContext);
                                  _runAction(
                                    messenger,
                                    () => adapter.repeatPost(
                                      targetPost.id,
                                      visibility: scope,
                                    ),
                                    '$boostLabelしました（${display.label}）',
                                  );
                                },
                              );
                            }).toList(),
                          ),
                        )
                      : null,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _runAction(
                      messenger,
                      () => adapter.repeatPost(targetPost.id),
                      '$boostLabelしました',
                    );
                  },
                ),
              if ((targetPost.scope == PostScope.public ||
                      targetPost.scope == PostScope.unlisted) &&
                  targetPost.url != null &&
                  hasOtherAccounts(ref))
                ListTile(
                  leading: const Icon(Icons.repeat),
                  title: Text('別アカウントで$boostLabel'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    showCrossAccountBoostPicker(
                      context: context,
                      ref: ref,
                      targetPost: targetPost,
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

  /// 実行と失敗の扱いは [PostActionRunner] に寄せた (#943)。以前は post_tile /
  /// post_touch_action_row にも同名・同構造の写しがあり、片方だけ直して
  /// `phase: post_action` の母数からこの導線が欠ける事故を繰り返していた。
  ///
  /// ⚠ 通知画面はタブの上に push されるので、ハッシュタグ / リストタブを開いた
  /// まま来ることがある。反映先を [readVisibleTimelines] で解決するのは runner
  /// 側に入っている (#887)。
  PostActionRunner _runner(ScaffoldMessengerState messenger) =>
      PostActionRunner(ref: ref, messenger: messenger);

  Future<void> _runAction(
    ScaffoldMessengerState messenger,
    Future<Post> Function() action,
    String successMessage,
  ) => _runner(messenger).run(action, successMessage);

  /// 通知本文中のカスタム絵文字をタップしたときに表示するアクションメニュー (#310)。
  /// post_tile 側と対称な実装。BottomSheet 自体は #396 で共通化。
  void _showEmojiActionMenu(
    BuildContext context,
    Post post,
    String shortcode,
    String emojiUrl,
  ) {
    final account = ref.read(currentAccountProvider);
    final adapter = account?.adapter;
    final targetPost = post.reblog ?? post;
    final messenger = ScaffoldMessenger.of(context);

    EmojiActionSheet.show(
      context: context,
      shortcode: shortcode,
      emojiUrl: emojiUrl,
      onReact: adapter is ReactionSupport
          ? () => _runReactionAction(
              messenger,
              adapter as BackendAdapter,
              targetPost.id,
              () => (adapter as ReactionSupport).addReaction(
                targetPost.id,
                ':$shortcode:',
              ),
              'リアクションしました',
            )
          : null,
    );
  }

  void _showEmojiPicker(BuildContext context) {
    final account = ref.read(currentAccountProvider);
    final adapter = account?.adapter;
    if (adapter is! ReactionSupport) return;

    final post = notification.post;
    if (post == null) return;
    final targetPost = post.reblog ?? post;
    final messenger = ScaffoldMessenger.of(context);
    final backend = adapter as BackendAdapter;
    final reaction = adapter as ReactionSupport;

    unawaited(
      showReactionPickerSheet(
        context: context,
        ref: ref,
        onSelected: (emoji) => _runReactionAction(
          messenger,
          backend,
          targetPost.id,
          () => reaction.addReaction(targetPost.id, emoji),
          'リアクションしました',
        ),
      ),
    );
  }

  Future<void> _runReactionAction(
    ScaffoldMessengerState messenger,
    BackendAdapter adapter,
    String postId,
    Future<void> Function() action,
    String successMessage, {
    String phase = 'reaction_add',
  }) => _runner(
    messenger,
  ).runReaction(adapter, postId, action, successMessage, phase: phase);

  Widget _buildHeader(BuildContext context, String label) {
    final theme = Theme.of(context);
    final user = notification.user;

    if (user == null) {
      return Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
          TimestampText(
            notification.createdAt,
            absolute: ref.watch(absoluteTimeProvider),
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
        TimestampText(
          notification.createdAt,
          absolute: ref.watch(absoluteTimeProvider),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  (IconData, String) get _iconAndLabel {
    final display = notificationTypeDisplay(
      notification.type,
      reblogLabel: widget.reblogLabel,
      postLabel: widget.postLabel,
    );
    return (display.icon, display.label);
  }

  /// 実績キー (`notes1` 等) を実績名（絵文字つき）に解決する (#918)。
  /// カタログに無い未知キーはキーをそのまま出す（新実績で壊れないため）。
  /// キー自体が無ければ汎用の「実績」に倒す。
  String _achievementLabel(String? key) {
    if (key == null) return '実績';
    final meta = achievementCatalog[key];
    if (meta == null) return key;
    return '${meta.emoji} ${meta.label}';
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

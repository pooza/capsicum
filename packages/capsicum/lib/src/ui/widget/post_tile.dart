import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yaml/yaml.dart';

import '../../constants.dart';
import '../../url_helper.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../service/server_metadata_cache.dart';
import '../../service/tco_resolver.dart';
import 'content_parser.dart';
import '../../provider/server_config_provider.dart';
import '../../provider/timeline_provider.dart';
import 'emoji_picker.dart';
import 'user_avatar.dart';
import 'emoji_text.dart';

String _stripHtml(String html) => stripHtml(html);

class PostTile extends ConsumerStatefulWidget {
  final Post post;
  final bool tappable;
  final bool initialExpanded;
  final bool selectable;
  final VoidCallback? onActionCompleted;
  final ValueChanged<Post>? onPostUpdated;

  const PostTile({
    super.key,
    required this.post,
    this.tappable = true,
    this.initialExpanded = false,
    this.selectable = false,
    this.onActionCompleted,
    this.onPostUpdated,
  });

  @override
  ConsumerState<PostTile> createState() => _PostTileState();
}

class _PostTileState extends ConsumerState<PostTile> {
  static const _maxLines = 8;
  static const _maxTags = 3;
  late bool _expanded = widget.initialExpanded;
  bool _tagsExpanded = false;
  late bool _cwExpanded = widget.initialExpanded;
  bool _filterExpanded = false;
  bool _deleted = false;
  List<PreviewCard> _fetchedCards = [];
  TranslationResult? _translation;
  bool _translating = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialExpanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFetchCard());
    }
    _resolveTcoUrls();
  }

  @override
  void didUpdateWidget(PostTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.id != widget.post.id) {
      _deleted = false;
      _expanded = widget.initialExpanded;
      _cwExpanded = widget.initialExpanded;
      _tagsExpanded = false;
      _filterExpanded = false;
      _fetchedCards = [];
      _translation = null;
      _translating = false;
    }
  }

  static final _tcoPattern = RegExp(r'https?://t\.co/\S+');

  void _resolveTcoUrls() {
    final content = (post.reblog ?? post).content;
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

  Future<void> _maybeFetchCard() async {
    final displayPost = post.reblog ?? post;
    if (displayPost.attachments.isNotEmpty) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! MisskeyAdapter) return;
    final content = displayPost.content ?? '';
    final urls = RegExp(
      r'https?://\S+',
    ).allMatches(content).map((m) => m.group(0)!).toList();
    if (urls.isEmpty) return;
    // Skip the first URL if the API already returned a card for it.
    final urlsToFetch = displayPost.card != null ? urls.skip(1) : urls;
    final cards = <PreviewCard>[];
    for (final url in urlsToFetch) {
      final card = await adapter.fetchUrlPreview(url);
      if (card != null) cards.add(card);
    }
    if (mounted && cards.isNotEmpty) {
      setState(() => _fetchedCards = cards);
    }
  }

  List<Widget> _buildPreviewCards(Post displayPost) {
    final cards = <PreviewCard>[
      if (displayPost.card != null) displayPost.card!,
      ..._fetchedCards,
    ];
    if (cards.isEmpty) return [];
    return [
      for (final card in cards)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _PreviewCardWidget(card: card),
        ),
    ];
  }

  Post get post => widget.post;
  VoidCallback? get onActionCompleted => widget.onActionCompleted;

  /// コマンドトゥート結果など、コードブロック表示すべき本文かどうか判定する。
  /// - 本文全体（メンション除去後）が JSON オブジェクト/配列 or YAML マッピングとしてパース可能
  /// - CW が「実行結果」で本文が YAML としてパース可能
  /// メンション除去後の本文テキストを返す。
  static String _stripMentions(String plainText) {
    return plainText.replaceAll(RegExp(r'@[\w.@-]+\s*'), '').trim();
  }

  /// コマンドトゥート結果など、コードブロック表示すべき本文かどうか判定する。
  bool _isStructuredContent(String plainText, String? spoilerText) {
    final body = _stripMentions(plainText);
    if (body.isEmpty) return false;

    // JSON オブジェクト/配列として有効か
    if (body.startsWith('{') || body.startsWith('[')) {
      try {
        final parsed = json.decode(body);
        if (parsed is Map || parsed is List) return true;
      } catch (_) {}
    }

    // YAML として Map/List にパースできるか — CW 付き投稿のみ対象
    // （CW なしだと `key: value` を含む普通の投稿が誤検知される）
    if (spoilerText != null && spoilerText.isNotEmpty) {
      try {
        final parsed = loadYaml(body);
        if (parsed is Map || parsed is List) return true;
      } catch (_) {}
    }

    return false;
  }

  Widget _buildCodeBlock(String plainText) {
    final body = _stripMentions(plainText);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'モロヘイヤ',
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey.shade600,
                fontFamily: 'monospace',
              ),
            ),
          ),
          SelectableText(
            body,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildContentText(InlineSpan contentSpan) {
    final textWidget = Text.rich(
      contentSpan,
      maxLines: _expanded ? null : _maxLines,
      overflow: _expanded ? null : TextOverflow.ellipsis,
    );
    if (widget.selectable) {
      return SelectionArea(child: textWidget);
    }
    return textWidget;
  }

  void _onMediaDescriptionUpdated(
    Post displayPost,
    List<Attachment> updatedAttachments,
  ) {
    final updatedPost = Post(
      id: displayPost.id,
      postedAt: displayPost.postedAt,
      author: displayPost.author,
      content: displayPost.content,
      scope: displayPost.scope,
      attachments: updatedAttachments,
      favouriteCount: displayPost.favouriteCount,
      reblogCount: displayPost.reblogCount,
      replyCount: displayPost.replyCount,
      quoteCount: displayPost.quoteCount,
      favourited: displayPost.favourited,
      reblogged: displayPost.reblogged,
      bookmarked: displayPost.bookmarked,
      sensitive: displayPost.sensitive,
      reactions: displayPost.reactions,
      myReaction: displayPost.myReaction,
      reactionEmojis: displayPost.reactionEmojis,
      inReplyToId: displayPost.inReplyToId,
      reblog: displayPost.reblog,
      quote: displayPost.quote,
      spoilerText: displayPost.spoilerText,
      emojis: displayPost.emojis,
      emojiHost: displayPost.emojiHost,
      card: displayPost.card,
      poll: displayPost.poll,
      filterAction: displayPost.filterAction,
      filterTitle: displayPost.filterTitle,
      pinned: displayPost.pinned,
      channelId: displayPost.channelId,
      channelName: displayPost.channelName,
      localOnly: displayPost.localOnly,
    );
    ref.read(timelineProvider.notifier).updatePost(updatedPost);
  }

  @override
  void dispose() {
    _contentRenderer?.dispose();
    super.dispose();
  }

  Future<void> _navigateToMention(String mention) async {
    // Parse @user or @user@host
    final parts = mention.replaceFirst('@', '').split('@');
    if (parts.isEmpty) return;
    final username = parts[0];
    final host = parts.length > 1 ? parts[1] : null;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;
    try {
      final user = await adapter.getUser(username, host);
      if (user != null && mounted) {
        context.push('/profile', extra: user);
      }
    } on Exception catch (e) {
      debugPrint('Failed to look up mention $mention: $e');
    }
  }

  ContentRenderer? _contentRenderer;

  TextSpan _renderContent(
    String content,
    TextStyle baseStyle,
    Map<String, String> emojis, {
    String? fallbackHost,
    required bool isHtml,
  }) {
    _contentRenderer?.dispose();
    _contentRenderer = ContentRenderer(
      baseStyle: baseStyle,
      resolveEmoji: (shortcode) {
        final url = emojis[shortcode];
        if (url != null) return url;
        if (fallbackHost != null) {
          return 'https://$fallbackHost/emoji/$shortcode.webp';
        }
        return null;
      },
      resolveUrl: (url) =>
          TcoResolver.isTcoUrl(url) ? TcoResolver.getCached(url) : null,
      onLinkTap: (url) {
        final uri = Uri.tryParse(url);
        if (uri == null) return;
        // Misskey Play リンクをアプリ内ブラウザで開く
        if (uri.pathSegments.length >= 2 && uri.pathSegments[0] == 'play') {
          final account = ref.read(accountManagerProvider).current;
          if (account != null && uri.host == account.key.host) {
            launchUrlSafely(uri, mode: LaunchMode.inAppBrowserView);
            return;
          }
        }
        launchUrlSafely(uri);
      },
      onHashtagTap: (tag) => context.push('/hashtag/$tag'),
      onMentionTap: (mention) => _navigateToMention(mention),
    );
    return isHtml
        ? _contentRenderer!.renderHtml(content)
        : _contentRenderer!.renderMfm(content);
  }

  @override
  Widget build(BuildContext context) {
    if (_deleted) return const SizedBox.shrink();

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

    final isDirect = displayPost.scope == PostScope.direct;

    return Container(
      color: isDirect
          ? Theme.of(
              context,
            ).colorScheme.primaryContainer.withValues(alpha: 0.3)
          : null,
      child: InkWell(
        onTap: widget.tappable
            ? () => context.push('/post', extra: post)
            : null,
        onLongPress: () => _showActionMenu(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 52),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (post.reblog != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: EmojiText(
                          '${post.author.displayName ?? post.author.username} が${ref.watch(reblogLabelProvider)}',
                          emojis: post.author.emojis,
                          style: Theme.of(context).textTheme.bodySmall,
                          fallbackHost: post.emojiHost,
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
                        if (displayPost.author.isBot) ...[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.smart_toy,
                            size: 14,
                            color: Theme.of(context).textTheme.bodySmall?.color,
                          ),
                        ],
                        if (displayPost.author.isGroup) ...[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.groups,
                            size: 14,
                            color: Theme.of(context).textTheme.bodySmall?.color,
                          ),
                        ],
                        for (final role in displayPost.author.roles)
                          ..._buildRoleIcon(context, role),
                        const SizedBox(width: 4),
                        Icon(
                          _scopeIcon(displayPost.scope),
                          size: 14,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                        if (displayPost.localOnly) ...[
                          const SizedBox(width: 2),
                          Icon(
                            Icons.edit_off,
                            size: 14,
                            color: Theme.of(context).textTheme.bodySmall?.color,
                          ),
                        ],
                        const SizedBox(width: 4),
                        Text(
                          _formatTime(displayPost.postedAt),
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
                    if (displayPost.author.host != null)
                      _buildInstanceTicker(context, displayPost.author.host!),
                    if (displayPost.channelName != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: GestureDetector(
                          onTap: displayPost.channelId != null
                              ? () => context.push(
                                  '/channel/${displayPost.channelId}',
                                  extra: displayPost.channelName,
                                )
                              : null,
                          child: Row(
                            children: [
                              Icon(
                                Icons.forum,
                                size: 14,
                                color: Theme.of(
                                  context,
                                ).textTheme.bodySmall?.color,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  displayPost.channelName!,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: displayPost.channelId != null
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary
                                            : null,
                                      ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (displayPost.inReplyToId != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            Icon(
                              Icons.reply,
                              size: 14,
                              color: Theme.of(
                                context,
                              ).textTheme.bodySmall?.color,
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
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
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
                          final rawContent = displayPost.content ?? '';
                          final isHtml =
                              rawContent.contains('<p>') ||
                              rawContent.contains('<br');
                          final parsed = isHtml
                              ? extractTrailingTagsHtml(rawContent)
                              : extractTrailingTagsMfm(rawContent);
                          final allEmojis = {
                            ...displayPost.emojis,
                            ...displayPost.author.emojis,
                          };
                          // 構造化テキスト判定用のプレーンテキスト
                          final plainBody = isHtml
                              ? stripHtml(parsed.body)
                              : parsed.body;
                          final isStructured = _isStructuredContent(
                            plainBody,
                            displayPost.spoilerText,
                          );
                          if (isStructured) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [_buildCodeBlock(plainBody)],
                            );
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  final baseStyle = DefaultTextStyle.of(
                                    context,
                                  ).style;
                                  final contentSpan = _renderContent(
                                    parsed.body,
                                    baseStyle,
                                    allEmojis,
                                    fallbackHost: displayPost.emojiHost,
                                    isHtml: isHtml,
                                  );
                                  // Use a plain TextSpan for overflow measurement
                                  // because TextPainter cannot measure WidgetSpan.
                                  // HTML の場合はタグ除去済みテキストで測定する。
                                  final measureSpan = TextSpan(
                                    text: isHtml ? plainBody : parsed.body,
                                    style: baseStyle,
                                  );
                                  final textPainter = TextPainter(
                                    text: measureSpan,
                                    maxLines: _maxLines,
                                    textDirection: TextDirection.ltr,
                                  )..layout(maxWidth: constraints.maxWidth);
                                  final overflows =
                                      textPainter.didExceedMaxLines;

                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _buildContentText(contentSpan),
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
                              if (_translating)
                                const Padding(
                                  padding: EdgeInsets.only(top: 8),
                                  child: SizedBox(
                                    height: 16,
                                    width: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ),
                              if (_translation != null)
                                Container(
                                  margin: const EdgeInsets.only(top: 8),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        [
                                          '翻訳',
                                          if (_translation!.provider != null)
                                            '(${_translation!.provider})',
                                        ].join(' '),
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      SelectableText(
                                        _stripHtml(
                                          _translation!.content,
                                        ).trim(),
                                      ),
                                    ],
                                  ),
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
                                              onPressed: () =>
                                                  context.push('/hashtag/$tag'),
                                            ),
                                          ),
                                      if (parsed.trailingTags.length > _maxTags)
                                        GestureDetector(
                                          onTap: () => setState(
                                            () =>
                                                _tagsExpanded = !_tagsExpanded,
                                          ),
                                          child: Chip(
                                            materialTapTargetSize:
                                                MaterialTapTargetSize
                                                    .shrinkWrap,
                                            visualDensity:
                                                VisualDensity.compact,
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
                      if (displayPost.quote != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _QuoteCard(quote: displayPost.quote!),
                        )
                      else if (displayPost.quoteState != null &&
                          displayPost.quoteState != QuoteState.accepted)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _QuoteStateCard(
                            state: displayPost.quoteState!,
                          ),
                        ),
                      if (displayPost.attachments.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _AttachmentThumbnails(
                            attachments: displayPost.attachments,
                            sensitive: displayPost.sensitive,
                            postAuthorId: displayPost.author.id,
                            postId: displayPost.id,
                            onAttachmentsUpdated: (updated) {
                              _onMediaDescriptionUpdated(displayPost, updated);
                            },
                          ),
                        ),
                      if (displayPost.attachments.isEmpty)
                        ..._buildPreviewCards(displayPost),
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
                        displayPost.favouriteCount > 0 ||
                        displayPost.quoteCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            if (displayPost.replyCount > 0) ...[
                              _CountChip(
                                icon: Icons.reply,
                                label: '返信',
                                count: displayPost.replyCount,
                              ),
                              const SizedBox(width: 8),
                            ],
                            if (displayPost.reblogCount > 0) ...[
                              _CountChip(
                                icon: Icons.repeat,
                                label: ref.watch(reblogLabelProvider),
                                count: displayPost.reblogCount,
                                onTap: () =>
                                    _showRebloggedBy(context, displayPost),
                              ),
                              const SizedBox(width: 8),
                            ],
                            if (displayPost.quoteCount > 0) ...[
                              _CountChip(
                                icon: Icons.format_quote,
                                label: '引用',
                                count: displayPost.quoteCount,
                              ),
                              const SizedBox(width: 8),
                            ],
                            if (displayPost.favouriteCount > 0) ...[
                              _CountChip(
                                icon: Icons.star_outline,
                                label: ref.watch(favouriteLabelProvider),
                                count: displayPost.favouriteCount,
                                onTap: () =>
                                    _showFavouritedBy(context, displayPost),
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
              Positioned(
                left: 0,
                top: 0,
                child: GestureDetector(
                  onTap: () =>
                      context.push('/profile', extra: displayPost.author),
                  child: UserAvatar(user: displayPost.author, size: 40),
                ),
              ),
            ],
          ),
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
              if (adapter is TranslationSupport &&
                  (adapter is! MastodonAdapter ||
                      adapter.isTranslationAvailable) &&
                  targetPost.scope != PostScope.direct &&
                  post.reblog == null &&
                  targetPost.language !=
                      Localizations.localeOf(context).languageCode)
                ListTile(
                  leading: const Icon(Icons.translate),
                  title: const Text('翻訳'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _translatePost(targetPost);
                  },
                ),
              if (!isOwn && adapter is ReportSupport)
                ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: const Text('通報'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _confirmReport(context, targetPost);
                  },
                ),
              if (isOwn && adapter is PinSupport) ...[
                const Divider(),
                ListTile(
                  leading: Icon(
                    targetPost.pinned
                        ? Icons.push_pin
                        : Icons.push_pin_outlined,
                  ),
                  title: Text(targetPost.pinned ? 'ピン留め解除' : 'ピン留め'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    final messenger = ScaffoldMessenger.of(context);
                    final pinAdapter = adapter as PinSupport;
                    if (targetPost.pinned) {
                      _runAction(
                        messenger,
                        () => pinAdapter.unpinPost(targetPost.id),
                        'ピン留めを解除しました',
                      );
                    } else {
                      _runAction(
                        messenger,
                        () => pinAdapter.pinPost(targetPost.id),
                        'ピン留めしました',
                      );
                    }
                  },
                ),
              ],
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
      ),
    );
  }

  Future<void> _translatePost(Post targetPost) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! TranslationSupport) return;

    final targetLang = Localizations.localeOf(context).languageCode;
    setState(() => _translating = true);
    try {
      final result = await (adapter as TranslationSupport).translatePost(
        targetPost.id,
        targetLang: targetLang,
      );
      if (mounted) setState(() => _translation = result);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('翻訳に失敗しました')));
      }
    } finally {
      if (mounted) setState(() => _translating = false);
    }
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
              _runVoidAction(messenger, () async {
                await adapter.deletePost(targetPost.id);
                ref.read(timelineProvider.notifier).removePost(targetPost.id);
                if (mounted) setState(() => _deleted = true);
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

  void _confirmReport(BuildContext context, Post targetPost) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ReportSupport) return;
    final messenger = ScaffoldMessenger.of(context);
    final commentController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('通報'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('この${ref.read(postLabelProvider)}をサーバー管理者に通報しますか？'),
            const SizedBox(height: 12),
            TextField(
              controller: commentController,
              decoration: const InputDecoration(
                hintText: '理由（任意）',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              final comment = commentController.text.trim();
              _runVoidAction(
                messenger,
                () => (adapter as ReportSupport).reportPost(
                  targetPost.id,
                  targetPost.author.id,
                  comment: comment.isNotEmpty ? comment : null,
                ),
                '通報しました',
              );
            },
            child: const Text('通報'),
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
              _runVoidAction(messenger, () async {
                await adapter.deletePost(targetPost.id);
                ref.read(timelineProvider.notifier).removePost(targetPost.id);
                if (mounted) setState(() => _deleted = true);
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
    final account = ref.read(currentAccountProvider);
    final adapter = account?.adapter;
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
          host: account!.key.host,
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
    Future<Post> Function() action,
    String successMessage,
  ) async {
    try {
      final updated = await action();
      ref.read(timelineProvider.notifier).updatePost(updated);
      widget.onPostUpdated?.call(updated);
      onActionCompleted?.call();
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (e) {
      messenger.showSnackBar(const SnackBar(content: Text('操作に失敗しました')));
    }
  }

  Future<void> _runVoidAction(
    ScaffoldMessengerState messenger,
    Future<void> Function() action,
    String successMessage,
  ) async {
    try {
      await action();
      onActionCompleted?.call();
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (e) {
      debugPrint('_runVoidAction failed: $e');
      if (e is DioException) {
        debugPrint('Response body: ${e.response?.data}');
      }
      messenger.showSnackBar(SnackBar(content: Text(_describeError(e))));
    }
  }

  String _describeError(Object e) {
    if (e is DioException) {
      final statusCode = e.response?.statusCode;
      if (statusCode == 403) {
        return '権限がありません。再ログインが必要な場合があります';
      }
      if (statusCode == 500) {
        return 'サーバー内部エラーが発生しました。サーバー管理者にお問い合わせください';
      }
    }
    return '操作に失敗しました';
  }

  void _showRetagSheet(BuildContext context, Post targetPost) {
    final mulukhiya = ref.read(currentMulukhiyaProvider);
    if (mulukhiya == null) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    final retagContent = targetPost.content ?? '';
    final retagIsHtml =
        retagContent.contains('<p>') || retagContent.contains('<br');
    final parsed = retagIsHtml
        ? extractTrailingTagsHtml(retagContent)
        : extractTrailingTagsMfm(retagContent);
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
            if (mounted) setState(() => _deleted = true);
            messenger.showSnackBar(const SnackBar(content: Text('タグを変更しました')));
          } catch (e) {
            messenger.showSnackBar(const SnackBar(content: Text('操作に失敗しました')));
          }
        },
      ),
    );
  }

  Widget _buildInstanceTicker(BuildContext context, String host) {
    final themeColors = ref.watch(hostThemeColorProvider);
    final color = resolveHostColor(themeColors, host);
    final cached = ServerMetadataCache.instance.getCached(host);
    final label = cached?.name ?? host;

    if (cached == null) {
      ServerMetadataCache.instance.fetch(host).then((_) {
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
      });
    }

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
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

  String _formatTime(DateTime postedAt) {
    if (ref.watch(absoluteTimeProvider)) {
      final local = postedAt.toLocal();
      return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
          '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    final diff = DateTime.now().toUtc().difference(postedAt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}秒前';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
    if (diff.inHours < 24) return '${diff.inHours}時間前';
    if (diff.inDays < 30) return '${diff.inDays}日前';
    final months = diff.inDays ~/ 30;
    if (months < 12) return '$monthsヶ月前';
    return '${diff.inDays ~/ 365}年前';
  }

  void _showFavouritedBy(BuildContext context, Post post) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;
    final label = adapter is ReactionSupport ? 'リアクション' : 'お気に入り';
    if (adapter is MastodonAdapter) {
      context.push(
        '/users',
        extra: {
          'title': label,
          'fetcher': (String? cursor) => adapter.getFavouritedBy(
            post.id,
            query: TimelineQuery(maxId: cursor, limit: 20),
          ),
        },
      );
    } else if (adapter is MisskeyAdapter) {
      context.push(
        '/users',
        extra: {
          'title': label,
          'fetcher': (String? cursor) => adapter.getReactedBy(
            post.id,
            query: TimelineQuery(maxId: cursor, limit: 20),
          ),
        },
      );
    }
  }

  void _showRebloggedBy(BuildContext context, Post post) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;
    final label = ref.read(reblogLabelProvider);
    if (adapter is MastodonAdapter) {
      context.push(
        '/users',
        extra: {
          'title': label,
          'fetcher': (String? cursor) => adapter.getRebloggedBy(
            post.id,
            query: TimelineQuery(maxId: cursor, limit: 20),
          ),
        },
      );
    } else if (adapter is MisskeyAdapter) {
      context.push(
        '/users',
        extra: {
          'title': label,
          'fetcher': (String? cursor) => adapter.getRenotedBy(
            post.id,
            query: TimelineQuery(maxId: cursor, limit: 20),
          ),
        },
      );
    }
  }

  List<Widget> _buildRoleIcon(BuildContext context, UserRole role) {
    final iconUrl = role.iconUrl;
    if (iconUrl == null && role.isAdmin) {
      // 管理者ロール: sabacan があればそれを使い、なければシールドアイコン
      final sabacanUrl = ref.watch(sabacanUrlProvider).valueOrNull;
      if (sabacanUrl != null) {
        return [
          const SizedBox(width: 4),
          Image.network(
            sabacanUrl,
            width: 14,
            height: 14,
            errorBuilder: (_, _, _) => Icon(
              Icons.shield,
              size: 14,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
        ];
      }
      final color =
          role.color != null &&
              role.color!.startsWith('#') &&
              role.color!.length >= 7
          ? Color(
              0xFF000000 | int.parse(role.color!.substring(1, 7), radix: 16),
            )
          : Theme.of(context).textTheme.bodySmall?.color;
      return [
        const SizedBox(width: 4),
        Icon(Icons.shield, size: 14, color: color),
      ];
    }
    if (iconUrl != null) {
      return [
        const SizedBox(width: 4),
        Image.network(
          iconUrl,
          width: 14,
          height: 14,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ];
    }
    return [];
  }

  IconData _scopeIcon(PostScope scope) {
    final isMisskey = ref.read(currentAdapterProvider) is ReactionSupport;
    switch (scope) {
      case PostScope.public:
        return Icons.public;
      case PostScope.unlisted:
        return isMisskey ? Icons.home_outlined : Icons.nightlight_outlined;
      case PostScope.followersOnly:
        return Icons.lock_outline;
      case PostScope.direct:
        return isMisskey ? Icons.mail_outline : Icons.alternate_email;
    }
  }
}

class _CountChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final VoidCallback? onTap;

  const _CountChip({
    required this.icon,
    required this.label,
    required this.count,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final color = style?.color;
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text('$label $count', style: style),
      ],
    );
    if (onTap != null) {
      return InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
          child: child,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: child,
    );
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
          // Strip host part: "name@." or "name@remote.host" → "name"
          final nameOnly = strippedKey.contains('@')
              ? strippedKey.substring(0, strippedKey.indexOf('@'))
              : strippedKey;
          var emojiUrl =
              post.reactionEmojis[strippedKey] ?? post.reactionEmojis[nameOnly];
          // Fallback: construct URL from Misskey emoji endpoint.
          if (emojiUrl == null && isCustomEmoji) {
            // Extract host from reaction key (e.g. "name@remote.host").
            // "@." means local server → use emojiHost (logged-in server).
            final atIndex = strippedKey.indexOf('@');
            final hostPart = atIndex >= 0
                ? strippedKey.substring(atIndex + 1)
                : null;
            final isLocal =
                hostPart == null || hostPart == '.' || hostPart.isEmpty;
            final emojiHost = isLocal
                ? (post.emojiHost ?? post.author.host)
                : hostPart;
            if (emojiHost != null) {
              emojiUrl = 'https://$emojiHost/emoji/$nameOnly.webp';
            }
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
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: 18,
                        maxWidth: 54,
                      ),
                      child: Image.network(
                        emojiUrl,
                        height: 18,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => Text(
                          entry.key,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Image.network(
                      _twemojiUrl(entry.key),
                      width: 18,
                      height: 18,
                      errorBuilder: (_, _, _) =>
                          Text(entry.key, style: const TextStyle(fontSize: 14)),
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

  /// Build Twemoji CDN URL from a Unicode emoji string.
  static String _twemojiUrl(String emoji) {
    final codepoints = emoji.runes
        .where((r) => r != 0xFE0F) // strip variation selectors
        .map((r) => r.toRadixString(16))
        .join('-');
    return '${AppConstants.twemojiBaseUrl}/$codepoints.png';
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
  bool _votedLocally = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.poll.voted ? widget.poll.ownVotes.toSet() : {};
  }

  @override
  void didUpdateWidget(covariant _PollWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.poll.id != widget.poll.id) {
      _selected = widget.poll.voted ? widget.poll.ownVotes.toSet() : {};
      _votedLocally = false;
    } else if (_votedLocally && widget.poll.voted) {
      // Server-updated data arrived; stop local adjustment.
      _selected = widget.poll.ownVotes.toSet();
      _votedLocally = false;
    }
  }

  bool get _hasVoted => widget.poll.voted || _votedLocally;
  bool get _showResults => _hasVoted || widget.poll.expired;

  Future<void> _vote() async {
    if (_selected.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    try {
      final adapter = ref.read(currentAdapterProvider);
      if (adapter != null && adapter is PollSupport) {
        await (adapter as PollSupport).votePoll(
          widget.poll.id,
          _selected.toList(),
        );
      }
    } catch (e) {
      debugPrint('Poll vote error: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('投票に失敗しました')));
      }
      return;
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
    if (mounted) setState(() => _votedLocally = true);
    try {
      widget.onActionCompleted?.call();
    } catch (e) {
      debugPrint('Poll vote onActionCompleted error: $e');
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

  int _adjustedVoteCount(int index) {
    final base = widget.poll.options[index].votesCount;
    if (_votedLocally && _selected.contains(index)) return base + 1;
    return base;
  }

  int get _adjustedTotalVotes {
    final base = widget.poll.options.fold<int>(0, (s, o) => s + o.votesCount);
    if (_votedLocally) return base + _selected.length;
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final poll = widget.poll;
    final totalVotes = _adjustedTotalVotes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < poll.options.length; i++)
          _buildOption(
            context,
            theme,
            PollOption(
              title: poll.options[i].title,
              votesCount: _adjustedVoteCount(i),
            ),
            i,
            totalVotes,
          ),
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
    final isOwnVote =
        widget.poll.ownVotes.contains(index) ||
        (_votedLocally && _selected.contains(index));

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

class _QuoteCard extends StatelessWidget {
  final Post quote;

  const _QuoteCard({required this.quote});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () => context.push('/post', extra: quote),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (quote.author.avatarUrl != null)
                  GestureDetector(
                    onTap: () => context.push('/profile', extra: quote.author),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.network(
                        quote.author.avatarUrl!,
                        width: 16,
                        height: 16,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                if (quote.author.avatarUrl != null) const SizedBox(width: 4),
                Expanded(
                  child: EmojiText(
                    quote.author.displayName ?? quote.author.username,
                    emojis: quote.author.emojis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (quote.content != null && quote.content!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                _stripHtml(quote.content!),
                style: theme.textTheme.bodySmall,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (quote.attachments.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    Icons.attach_file,
                    size: 14,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    '${quote.attachments.length}件の添付',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _QuoteStateCard extends StatelessWidget {
  final QuoteState state;

  const _QuoteStateCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, label) = switch (state) {
      QuoteState.pending => (Icons.hourglass_empty, '引用元の承認待ちです'),
      QuoteState.rejected => (Icons.block, '引用が拒否されました'),
      QuoteState.deleted => (Icons.delete_outline, '引用元の投稿が削除されました'),
      QuoteState.unauthorized => (Icons.lock_outline, '引用元を表示する権限がありません'),
      QuoteState.accepted => (Icons.format_quote, ''),
    };
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.hintColor),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
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
        if (uri != null) launchUrlSafely(uri);
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
  final String? postAuthorId;
  final String? postId;
  final ValueChanged<List<Attachment>>? onAttachmentsUpdated;

  const _AttachmentThumbnails({
    required this.attachments,
    this.sensitive = false,
    this.postAuthorId,
    this.postId,
    this.onAttachmentsUpdated,
  });

  @override
  State<_AttachmentThumbnails> createState() => _AttachmentThumbnailsState();
}

class _AttachmentThumbnailsState extends State<_AttachmentThumbnails> {
  bool _revealed = false;

  Future<void> _openMediaViewer(
    BuildContext context,
    List<Attachment> attachments,
    int index,
  ) async {
    final result = await context.push<List<Attachment>>(
      '/media',
      extra: {
        'attachments': attachments,
        'initialIndex': index,
        'postAuthorId': widget.postAuthorId,
        'postId': widget.postId,
      },
    );
    if (result != null) {
      widget.onAttachmentsUpdated?.call(result);
    }
  }

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
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 400),
        child: _buildThumbnail(
          context,
          images.first,
          0,
          images,
          fit: BoxFit.contain,
        ),
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
                            onTap: () => _openMediaViewer(context, images, 3),
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
    List<Attachment> images, {
    BoxFit fit = BoxFit.cover,
  }) {
    final imageUrl = attachment.previewUrl ?? attachment.url;
    final isSensitive = widget.sensitive && !_revealed;

    return GestureDetector(
      onTap: () {
        if (isSensitive) {
          setState(() => _revealed = true);
        } else {
          _openMediaViewer(context, images, index);
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
                fit: fit,
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
            if (!isSensitive &&
                (attachment.type == AttachmentType.video ||
                    attachment.type == AttachmentType.gifv))
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
        onTap: () => _openMediaViewer(context, [audio], 0),
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

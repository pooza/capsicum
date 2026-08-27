import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:yaml/yaml.dart';

import '../../constants.dart';
import '../../platform/platform_info.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../service/server_metadata_cache.dart';
import '../../service/tco_resolver.dart';
import '../../service/url_preview_cache.dart';
import '../../util/exception_scrub.dart';
import '../util/fediverse_link.dart';
import '../util/hashtag_actions.dart';
import '../util/post_action_error.dart';
import '../util/post_actions.dart';
import '../util/post_scope_display.dart';
import '../util/relative_time.dart';
import '../util/user_acct.dart';
import '../util/visible_timeline.dart';
import 'content_parser.dart';
import 'cross_account_boost.dart';
import 'emoji_action_sheet.dart';
import 'emoji_text.dart';
import 'home_menu.dart' show pickFollowedChannel;
import 'inline_custom_emoji.dart';
import 'post_touch_action_row.dart';
import 'preview_card_widget.dart';
import 'reaction_picker_sheet.dart';
import 'report_comment_dialog.dart';
import 'user_avatar.dart';

String _stripHtml(String html) => stripHtml(html);

class PostTile extends ConsumerStatefulWidget {
  final Post post;
  final bool tappable;
  final bool initialExpanded;
  final bool selectable;

  /// キーボードナビゲーション (#849) で選択中の投稿。ハイライトを出すだけで、
  /// タップ操作の対象や状態には影響しない。
  final bool selected;
  final VoidCallback? onActionCompleted;
  final ValueChanged<Post>? onPostUpdated;

  const PostTile({
    super.key,
    required this.post,
    this.tappable = true,
    this.initialExpanded = false,
    this.selectable = false,
    this.selected = false,
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

  /// 自分で削除した投稿の id。**bool ではなく id で持つ** (#909)。
  ///
  /// タイムラインの各行にはキーが無く、State は位置で再利用される。削除の直前に
  /// streaming が新着を先頭へ挿すと、この State が描く投稿が別のものへ入れ替わる
  /// ので、bool だと**無関係な投稿を隠してしまう**。「削除してタグづけ」は
  /// モロヘイヤが投稿→削除の順で行い、レスポンスが返る前に再投稿が streaming で
  /// 届くため、これがそのまま「再投稿が出てこない」に化けていた。
  String? _deletedPostId;
  List<PreviewCard> _fetchedCards = [];
  // カード取得対象の URL（本文中で API 由来カードに含まれない分）。順序保持。
  List<String> _cardUrlsToFetch = const [];
  // 未キャッシュ URL の取得デバウンス。スクロールで一瞬映っただけの投稿まで
  // summaly を叩かないよう、少し待ってから取得する (#772)。
  Timer? _cardFetchDebounce;
  TranslationResult? _translation;
  bool _translating = false;

  @override
  void initState() {
    super.initState();
    _prepareCardFetch();
    _resolveTcoUrls();
  }

  @override
  void didUpdateWidget(PostTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.id != widget.post.id) {
      _deletedPostId = null;
      _expanded = widget.initialExpanded;
      _cwExpanded = widget.initialExpanded;
      _tagsExpanded = false;
      _filterExpanded = false;
      _fetchedCards = [];
      _cardUrlsToFetch = const [];
      _cardFetchDebounce?.cancel();
      _translation = null;
      _translating = false;
      _prepareCardFetch();
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

  /// Misskey の本文中 URL からプレビューカードを取得する準備をする (#772)。
  ///
  /// Misskey の note にはカードが含まれないため URL ごとに summaly を叩く。
  /// タイムラインでも表示するが、全投稿で無差別に fetch するとサーバー負荷が
  /// 大きいので次の 3 段でコストを抑える:
  ///
  /// - キャッシュ済み URL は即時反映し fetch しない（[UrlPreviewCache]）
  /// - 未キャッシュ分はデバウンス後に取得（スクロールで一瞬映った投稿は
  ///   dispose で timer が消え取得されない）
  /// - 「プレビューカード非表示」設定のときは取得ごと止める（コスト回避）
  void _prepareCardFetch() {
    final displayPost = post.reblog ?? post;
    if (displayPost.attachments.isNotEmpty) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! MisskeyAdapter) return;
    // 非表示設定のユーザーは summaly コストごと避けられるようにする (#772)。
    if (ref.read(previewCardModeProvider) == PreviewCardMode.hide) return;
    final content = displayPost.content ?? '';
    // `\S+` だと空白なしで続く日本語（`…fooをご覧ください`）まで URL に取り込み、
    // summaly が壊れた URL で失敗して negative キャッシュされ、本来出るカードが
    // 出なくなる。空白・引用/括弧・CJK 記号/かな/漢字/全角（U+3000-30FF・
    // U+4E00-9FFF・U+FF00-FFEF）を境界として除外する (#772)。
    final urls = RegExp(
      r'''https?://[^\s<>"'()\[\]{}　-ヿ一-鿿＀-￯]+''',
    ).allMatches(content).map((m) => m.group(0)!).toList();
    if (urls.isEmpty) return;
    // API が既にカードを返した先頭 URL は二重取得しない。
    _cardUrlsToFetch = (displayPost.card != null ? urls.skip(1) : urls)
        .toList();
    if (_cardUrlsToFetch.isEmpty) return;

    // キャッシュ済みは初回描画に間に合わせて即時反映（fetch 不要）。
    _rebuildCardsFromCache();
    if (_cardUrlsToFetch.every(UrlPreviewCache.instance.has)) return;

    _cardFetchDebounce = Timer(const Duration(milliseconds: 500), _fetchCards);
  }

  /// 取得対象 URL のうちキャッシュ済みのものを本文の URL 順で [_fetchedCards]
  /// に組み立てる。取得後の反映と初回のキャッシュヒット反映で共用。
  void _rebuildCardsFromCache() {
    final cards = <PreviewCard>[];
    for (final url in _cardUrlsToFetch) {
      final card = UrlPreviewCache.instance.cached(url);
      if (card != null) cards.add(card);
    }
    _fetchedCards = cards;
  }

  Future<void> _fetchCards() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! MisskeyAdapter) return;
    for (final url in _cardUrlsToFetch) {
      if (UrlPreviewCache.instance.has(url)) continue;
      await UrlPreviewCache.instance.fetch(
        url,
        () => adapter.fetchUrlPreview(url),
      );
    }
    if (mounted) setState(_rebuildCardsFromCache);
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
          child: PreviewCardWidget(card: card),
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

  /// コマンドトゥート（または実行結果）かどうか判定する。
  /// - Map にパース可能かつ `command` キーを持つ（コマンドトゥート本体）
  /// - Map にパース可能かつ CW が「実行結果」（コマンドトゥートの結果）
  bool _isStructuredContent(String plainText, String? spoilerText) {
    final body = _stripMentions(plainText);
    if (body.isEmpty) return false;

    dynamic parsed;

    // JSON としてパース
    if (body.startsWith('{')) {
      try {
        parsed = json.decode(body);
      } catch (_) {}
    }

    // YAML としてパース
    if (parsed == null) {
      try {
        final yamlParsed = loadYaml(body);
        if (yamlParsed is Map) parsed = yamlParsed;
      } catch (_) {}
    }

    if (parsed is! Map) return false;

    // コマンドトゥート本体: `command` キーを持つ
    if (parsed.containsKey('command')) return true;

    // 実行結果: CW が「実行結果」
    if (spoilerText == '実行結果') return true;

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
          // コマンドトゥート結果 (JSON/YAML) は長い 1 行を折り返さず横
          // スクロールで読む。content_parser の codeBlock (#434) と同じ
          // 扱いに揃える (#585。従来この経路だけ softWrap 抑止が無く、
          // _isStructuredContent で検出できても折り返していた)。
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(
              body,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
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
    final updatedPost = displayPost.copyWith(attachments: updatedAttachments);
    readVisibleTimelines(ref).updatePost(updatedPost);
  }

  @override
  void dispose() {
    _cardFetchDebounce?.cancel();
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
      debugLogException('Failed to look up mention $mention', e);
    }
  }

  ContentRenderer? _contentRenderer;

  TextSpan _renderContent(
    String content,
    TextStyle baseStyle,
    Map<String, String> emojis, {
    String? fallbackHost,
    required bool isHtml,
    bool isCat = false,
  }) {
    _contentRenderer?.dispose();
    _contentRenderer = ContentRenderer(
      baseStyle: baseStyle,
      applyNyaize: isCat,
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
      // fediverse 投稿 / アカウント URL はアプリ内へ resolve し、自ホストの
      // Misskey Play はネイティブ画面で開く。Play の分岐は openFediverseLink に
      // 集約済み (#820 / #830)。
      onLinkTap: (url) => openFediverseLink(context, ref, url),
      onLinkLongPress: (url) {
        Clipboard.setData(ClipboardData(text: url));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('URL をコピーしました'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      onHashtagTap: (tag) => showHashtagActionMenu(context, tag),
      onMentionTap: (mention) => _navigateToMention(mention),
      onEmojiTap: (shortcode, emojiUrl) =>
          _showEmojiActionMenu(context, shortcode, emojiUrl),
      emojiSize: ref.watch(emojiSizeProvider),
      animateMfm: ref.watch(mfmAnimationEnabledProvider),
    );
    return isHtml
        ? _contentRenderer!.renderHtml(content)
        : _contentRenderer!.renderMfm(content);
  }

  @override
  Widget build(BuildContext context) {
    // いま描いている投稿そのものを削除したときだけ隠す。ブースト経由の削除は
    // 対象が内側の投稿になるので、そちらの id とも突き合わせる。
    final deletedId = _deletedPostId;
    if (deletedId != null &&
        (deletedId == widget.post.id || deletedId == widget.post.reblog?.id)) {
      return const SizedBox.shrink();
    }

    final displayPost = post.reblog ?? post;
    final isFilteredWarn = displayPost.filterAction == FilterAction.warn;
    final hideInstanceTicker = ref.watch(hideInstanceTickerProvider);

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
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      // キーボード選択中はスレッドの対象ハイライト / DM の色づけより濃く塗り、
      // どちらと重なっても「いまカーソルがある行」が判別できるようにする (#849)。
      color: widget.selected
          ? colorScheme.primaryContainer.withValues(alpha: 0.7)
          : isDirect
          ? colorScheme.primaryContainer.withValues(alpha: 0.3)
          : null,
      child: InkWell(
        onTap: widget.tappable
            ? () => context.push('/post', extra: post)
            : null,
        onLongPress: () => _showActionMenu(context),
        // デスクトップでは右クリックも長押しと同じアクションメニューを開く。
        onSecondaryTap: () => _showActionMenu(context),
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
                        // グループ（AP Group アクター）の Announce は通常のブースト
                        // と区別し、グループアイコン＋プロフィール導線を出す (#811)。
                        child: post.author.isGroup
                            ? _buildGroupReblogHeader(context, post)
                            // 「X がブースト」のヘッダーから、拡散したアカウント
                            // 本人（= post.author）のプロフィールへ飛べるようにする
                            // (#850)。グループヘッダー (#811) と同じく、タイル本体の
                            // onTap（/post 遷移）より内側の GestureDetector を優先。
                            : GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => context.push(
                                  '/profile',
                                  extra: post.author,
                                ),
                                child: EmojiText(
                                  '${post.author.displayName ?? post.author.username} が${ref.watch(reblogLabelProvider)}',
                                  emojis: post.author.emojis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                  fallbackHost: post.emojiHost,
                                ),
                              ),
                      ),
                    // 末尾アイコン列 (bot / group / role / scope / localOnly /
                    // 時刻) はレイアウト幅 60% を上限とした ConstrainedBox に
                    // 入れて Row 右端に張り付かせる。intrinsic がその上限を
                    // 超える狭幅ウィンドウでは FittedBox(scaleDown) で縮める。
                    // 元実装は Flexible(flex:1) で半幅枠を確保していたため、
                    // intrinsic が小さくても枠が Row 中央に張り付いて見えていた
                    // (#542)。Wrap で改行する案もあるが行高が動くと TL の
                    // リズムが崩れるので単行スケールに倒す (#495)。
                    LayoutBuilder(
                      builder: (context, constraints) => Row(
                        children: [
                          Expanded(
                            child: EmojiText(
                              displayPost.author.displayName ??
                                  displayPost.author.username,
                              emojis: displayPost.author.emojis,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              fallbackHost: displayPost.emojiHost,
                            ),
                          ),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: constraints.maxWidth * 0.6,
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (displayPost.author.isBot) ...[
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.smart_toy,
                                      size: 14,
                                      color: Theme.of(
                                        context,
                                      ).textTheme.bodySmall?.color,
                                    ),
                                  ],
                                  if (displayPost.author.isGroup) ...[
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.groups,
                                      size: 14,
                                      color: Theme.of(
                                        context,
                                      ).textTheme.bodySmall?.color,
                                    ),
                                  ],
                                  for (final role in displayPost.author.roles)
                                    ..._buildRoleIcon(context, role),
                                  const SizedBox(width: 4),
                                  _maybeDesktopTooltip(
                                    _scopeLabel(displayPost.scope),
                                    Icon(
                                      _scopeIcon(displayPost.scope),
                                      size: 14,
                                      color: Theme.of(
                                        context,
                                      ).textTheme.bodySmall?.color,
                                    ),
                                  ),
                                  if (displayPost.localOnly) ...[
                                    const SizedBox(width: 2),
                                    Icon(
                                      Icons.edit_off,
                                      size: 14,
                                      color: Theme.of(
                                        context,
                                      ).textTheme.bodySmall?.color,
                                    ),
                                  ],
                                  const SizedBox(width: 4),
                                  _maybeDesktopTooltip(
                                    _absoluteTimeTooltip(displayPost.postedAt),
                                    Text(
                                      _formatTime(displayPost.postedAt),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      _handleText(displayPost.author),
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (displayPost.author.host != null && !hideInstanceTicker)
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
                          final isHtml = displayPost.isHtml;
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
                                    isCat: displayPost.author.isCat,
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
                                                  showHashtagActionMenu(
                                                    context,
                                                    tag,
                                                  ),
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
                                hoverPost: displayPost,
                                hoverKind: _CountHoverKind.reblog,
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
                                hoverPost: displayPost,
                                hoverKind: _CountHoverKind.favourite,
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
                    PostTouchActionRow(
                      targetPost: displayPost,
                      outerPost: post,
                      onPostUpdated: widget.onPostUpdated,
                      onActionCompleted: onActionCompleted,
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
              Positioned(
                right: 0,
                top: post.reblog != null ? 28 : 8,
                child: GestureDetector(
                  onTap: () => _showActionMenu(context),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(
                      Icons.more_horiz,
                      size: 24,
                      color: Theme.of(context).textTheme.bodySmall?.color,
                    ),
                  ),
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
        phase: ReactionPhase.remove,
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

  /// ブースト / リノートの取り消し (#561)。実体は [PostActionRunner.unrepeat]
  /// で、以前あった `post_touch_action_row._unrepeat` との双子はそこへ寄せた
  /// (#943)。
  Future<void> _unrepeat(
    ScaffoldMessengerState messenger,
    BackendAdapter adapter,
    Post targetPost,
    bool isOwnRenote,
    String boostLabel,
  ) => _runner(messenger).unrepeat(
    adapter: adapter,
    outerPost: post,
    targetPost: targetPost,
    isOwnRenote: isOwnRenote,
    boostLabel: boostLabel,
  );

  /// シートを閉じた後に本体を呼ぶ (#996)。
  ///
  /// ⚠ **シートは `showModalBottomSheet` で開くので、この [PostTile] の dispose を
  /// 生き延びる。** 開いている間に背後の TL が更新されてタイルが捨てられると、
  /// 項目の処理にある `ref.read` / `context.push` が同期的に StateError を投げる。
  /// しかもその多くは API 呼び出しより**前**にあるため、**操作が送信されないまま
  /// 成功も失敗も出ずに消える**（Sentry CAPSICUM-4R）。
  ///
  /// #990 では `_showEmojiPicker` 1 経路にだけ `mounted` 判定を足したが、同じ
  /// シートから呼ばれる残り 6 経路が素通りしていた。母数はメソッド単位ではなく
  /// **「シートの項目全部」**なので、[_sheetItem] を通す形に寄せてある。
  ///
  /// [messenger] はシートを開く前に捕まえたものなので、タイルが死んでいても使える。
  void _dispatchFromSheet(
    ScaffoldMessengerState messenger,
    VoidCallback onSelected,
  ) {
    if (mounted) {
      onSelected();
      return;
    }
    // ⚠ **黙って捨てない。** これまでは StateError が unhandled で上がるだけで、
    // ユーザーには「押したのに何も起きない」としか見えなかった。
    messenger.showSnackBar(
      const SnackBar(content: Text('タイムラインが更新されたため、この投稿への操作を実行できませんでした')),
    );
    unawaited(
      Sentry.captureMessage(
        'post_tile.action_sheet.tile_disposed',
        level: SentryLevel.warning,
        withScope: (scope) => scope.setTag('phase', 'post_action'),
      ),
    );
  }

  /// アクションシートの項目を組む (#996)。
  ///
  /// ⚠ **項目を素の [ListTile] で足さない。** ここを通せば「シートを閉じる →
  /// [_dispatchFromSheet] で `mounted` を見る」が必ず挟まる。理由は
  /// [_dispatchFromSheet] の doc。
  Widget _sheetItem({
    required BuildContext sheetContext,
    required ScaffoldMessengerState messenger,
    required Widget leading,
    required Widget title,
    required VoidCallback onSelected,
    Widget? subtitle,
  }) => ListTile(
    leading: leading,
    title: title,
    subtitle: subtitle,
    onTap: () {
      Navigator.pop(sheetContext);
      _dispatchFromSheet(messenger, onSelected);
    },
  );

  /// チャンネル内へのリノート (#895)。ピッカーを挟むので単独のメソッドにしてある。
  Future<void> _repeatToChannel(
    ScaffoldMessengerState messenger,
    BackendAdapter adapter,
    Post targetPost,
    String boostLabel,
  ) async {
    final channel = await pickFollowedChannel(
      context,
      ref,
      title: 'チャンネルに$boostLabel',
    );
    // ピッカーを開いている間にタイルが捨てられていることがある
    // （_runAction 内の ref.read が落ちる / #665 と同型）。
    if (channel == null || !mounted) return;
    await _runVoidAction(
      messenger,
      () => (adapter as ChannelSupport).repeatPostToChannel(
        targetPost.id,
        channelId: channel.id,
      ),
      '「${channel.name}」に$boostLabelしました',
    );
  }

  void _showActionMenu(BuildContext context) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    final currentUser = ref.read(currentAccountProvider)?.user;
    final targetPost = post.reblog ?? post;
    final isOwn = currentUser != null && targetPost.author.id == currentUser.id;
    final isOwnRenote =
        post.reblog != null &&
        currentUser != null &&
        post.author.id == currentUser.id;
    final canUnrepeat = isOwnRenote || targetPost.reblogged;
    final messenger = ScaffoldMessenger.of(context);
    final boostLabel = ref.read(reblogLabelProvider);
    final bookmarkLabel = ref.read(bookmarkLabelProvider);
    // メニューを開いた時点の locale を確定させておく。BottomSheet の rebuild 時に
    // 外側 PostTile の context が deactivate 済みだと Localizations.localeOf が
    // null check で落ちるため、ここで一度だけ解決して閉包に取り込む（#659）。
    final locale = Localizations.localeOf(context);
    final postHashtags = extractHashtags(
      targetPost.content ?? '',
      isHtml: targetPost.isHtml,
    );
    final canRetag = _canRetag(targetPost);
    final hasNowPlayingTag = _hasNowPlayingTag(targetPost);
    final hasMulukhiya = ref.read(currentMulukhiyaProvider) != null;
    final canBoostToOtherAccount =
        (targetPost.scope == PostScope.public ||
            targetPost.scope == PostScope.unlisted) &&
        targetPost.url != null &&
        hasOtherAccounts(ref);

    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        // ⚠ **`sheetContext` で解決する。** タイルの context はシートが開いている
        // 間に defunct になりうる（#659 の locale と同型）。
        final errorColor = Theme.of(sheetContext).colorScheme.error;
        Widget item({
          required Widget leading,
          required Widget title,
          required VoidCallback onSelected,
          Widget? subtitle,
        }) => _sheetItem(
          sheetContext: sheetContext,
          messenger: messenger,
          leading: leading,
          title: title,
          subtitle: subtitle,
          onSelected: onSelected,
        );

        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                item(
                  leading: const Icon(Icons.reply),
                  title: const Text('リプライ'),
                  onSelected: () =>
                      context.push('/compose', extra: {'replyTo': targetPost}),
                ),
                if (targetPost.quotable)
                  item(
                    leading: const Icon(Icons.format_quote),
                    title: const Text('引用'),
                    onSelected: () => context.push(
                      '/compose',
                      extra: {'quoteTo': targetPost},
                    ),
                  ),
                if (adapter is FavoriteSupport)
                  item(
                    leading: const Icon(Icons.star_outline),
                    title: const Text('お気に入り'),
                    onSelected: () => _runAction(
                      messenger,
                      () => (adapter as FavoriteSupport).favoritePost(
                        targetPost.id,
                      ),
                      'お気に入りに追加しました',
                    ),
                  ),
                if (adapter is ReactionSupport)
                  item(
                    leading: const Icon(Icons.add_reaction_outlined),
                    title: const Text('リアクション'),
                    onSelected: () => _showEmojiPicker(context),
                  ),
                if (targetPost.scope == PostScope.public ||
                    targetPost.scope == PostScope.unlisted)
                  item(
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
                                final display = postScopeDisplay(
                                  scope,
                                  adapter,
                                );
                                return ActionChip(
                                  avatar: Icon(display.icon, size: 16),
                                  label: Text(display.label),
                                  onPressed: () {
                                    Navigator.pop(sheetContext);
                                    // ⚠ chip は ListTile の外なので [_sheetItem] を
                                    // 通らない。ガードを手で挟む (#996)。
                                    _dispatchFromSheet(
                                      messenger,
                                      () => _runAction(
                                        messenger,
                                        () => adapter.repeatPost(
                                          targetPost.id,
                                          visibility: scope,
                                        ),
                                        '$boostLabelしました（${display.label}）',
                                      ),
                                    );
                                  },
                                );
                              }).toList(),
                            ),
                          )
                        : null,
                    onSelected: () => _runAction(
                      messenger,
                      () => adapter.repeatPost(targetPost.id),
                      '$boostLabelしました',
                    ),
                  ),
                // チャンネル内へのリノート (#895)。通常のリノートはチャンネル外に
                // 出るため、チャンネルへ流したいときはこちらを選ぶ。滅多に使わない
                // 操作なので、既定（＝上の項目）はチャンネル指定なしのまま。
                if (adapter is ChannelSupport &&
                    (targetPost.scope == PostScope.public ||
                        targetPost.scope == PostScope.unlisted))
                  item(
                    leading: const Icon(Icons.forum),
                    title: Text('チャンネルに$boostLabel'),
                    onSelected: () => unawaited(
                      _repeatToChannel(
                        messenger,
                        adapter,
                        targetPost,
                        boostLabel,
                      ),
                    ),
                  ),
                if (canBoostToOtherAccount)
                  item(
                    leading: const Icon(Icons.repeat),
                    title: Text('別アカウントで$boostLabel'),
                    onSelected: () => showCrossAccountBoostPicker(
                      context: context,
                      ref: ref,
                      targetPost: targetPost,
                    ),
                  ),
                if (canUnrepeat)
                  item(
                    leading: const Icon(Icons.repeat_on),
                    title: Text('$boostLabelを取り消す'),
                    onSelected: () => _unrepeat(
                      messenger,
                      adapter,
                      targetPost,
                      isOwnRenote,
                      boostLabel,
                    ),
                  ),
                if (adapter is BookmarkSupport)
                  item(
                    leading: const Icon(Icons.bookmark_outline),
                    title: Text(bookmarkLabel),
                    onSelected: () => _runAction(
                      messenger,
                      () => (adapter as BookmarkSupport).bookmarkPost(
                        targetPost.id,
                      ),
                      '$bookmarkLabelに追加しました',
                    ),
                  ),
                if (targetPost.url != null)
                  item(
                    leading: const Icon(Icons.link),
                    title: const Text('URL をコピー'),
                    onSelected: () {
                      Clipboard.setData(ClipboardData(text: targetPost.url!));
                      messenger.showSnackBar(
                        const SnackBar(content: Text('URL をコピーしました')),
                      );
                    },
                  ),
                if (postHashtags.isNotEmpty)
                  item(
                    leading: const Icon(Icons.tag),
                    title: const Text('全ハッシュタグをコピー'),
                    onSelected: () {
                      Clipboard.setData(
                        ClipboardData(
                          text: postHashtags.map((t) => '#$t').join(' '),
                        ),
                      );
                      messenger.showSnackBar(
                        const SnackBar(content: Text('ハッシュタグをコピーしました')),
                      );
                    },
                  ),
                if (adapter is TranslationSupport &&
                    (adapter is! MastodonAdapter ||
                        adapter.isTranslationAvailable) &&
                    targetPost.scope != PostScope.direct &&
                    post.reblog == null &&
                    targetPost.language != locale.languageCode)
                  item(
                    leading: const Icon(Icons.translate),
                    title: const Text('翻訳'),
                    onSelected: () => unawaited(_translatePost(targetPost)),
                  ),
                if (!isOwn && adapter is ReportSupport)
                  item(
                    leading: const Icon(Icons.flag_outlined),
                    title: const Text('通報'),
                    onSelected: () =>
                        unawaited(_confirmReport(context, targetPost)),
                  ),
                if (isOwn && adapter is PinSupport) ...[
                  const Divider(),
                  item(
                    leading: Icon(
                      targetPost.pinned
                          ? Icons.push_pin
                          : Icons.push_pin_outlined,
                    ),
                    title: Text(targetPost.pinned ? 'ピン留め解除' : 'ピン留め'),
                    onSelected: () {
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
                  if (hasMulukhiya) ...[
                    if (canRetag)
                      item(
                        leading: const Icon(Icons.sell_outlined),
                        title: const Text('削除してタグづけ'),
                        onSelected: () => _showRetagSheet(context, targetPost),
                      ),
                    if (hasNowPlayingTag)
                      item(
                        leading: const Icon(Icons.music_off_outlined),
                        title: const Text('NowPlaying を削除'),
                        onSelected: () =>
                            _confirmDeleteNowPlaying(context, targetPost),
                      ),
                  ],
                  item(
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('削除して再編集'),
                    onSelected: () =>
                        _confirmDeleteAndRedraft(context, targetPost),
                  ),
                  item(
                    leading: Icon(Icons.delete_outline, color: errorColor),
                    title: Text('削除', style: TextStyle(color: errorColor)),
                    onSelected: () => _confirmDelete(context, targetPost),
                  ),
                ],
              ],
            ),
          ),
        );
      },
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
    // ⚠ **ダイアログ / シートを開く前に捕まえる** (#990)。コールバックは
    // 閉じた後に走るので、その間に背後の TL が更新されてこのタイルが
    // dispose されていると `ref.read` が StateError を投げる。しかもその
    // 呼び出しが API 呼び出しより**前**にあるため、**操作が送信されないまま
    // 成功も失敗も出ずに消える**。
    final timeline = readVisibleTimelines(ref);
    // ⚠ **ラベルも同じ理由で開く前に確定させる (#1009)。** ダイアログのボタンは
    // シートの項目タップ (#996) より**さらに後**に押されるので、`ref.read` を
    // `onPressed` に置くと dispose 済みで投げる。しかも投げるのは
    // `deletePost` より前で、CAPSICUM-4R と同じ「送信されないまま成功も失敗も
    // 出ない」形になる。
    final postLabel = ref.read(postLabelProvider);

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('$postLabelを削除'),
        content: Text('この$postLabelを削除しますか？この操作は取り消せません。'),
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
                timeline.removePost(targetPost.id);
                if (mounted) setState(() => _deletedPostId = targetPost.id);
                if (context.mounted) _popIfInThread(context);
              }, '$postLabelを削除しました');
            },
            child: Text(
              '削除',
              // ⚠ **タイルの context から取らない (#659)。**ダイアログが再ビルド
              // される（キーボード開閉・回転・テーマ変更）と、dispose 済みの
              // Element を辿って落ちる。
              style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReport(BuildContext context, Post targetPost) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ReportSupport) return;
    final messenger = ScaffoldMessenger.of(context);
    // 理由は [_confirmDelete] の同名コメント (#1009)。文面はダイアログを開く前に
    // 組む（builder の中で `ref` を読むと、キーボードの開閉で再ビルドされたとき
    // に dispose 済みで投げる）。
    final postLabel = ref.read(postLabelProvider);

    // 通報の宛先はアカウントで、投稿は証拠として添えるもの (#998)。
    // Mastodon の `POST /api/v1/reports` は account_id が必須・status_ids が
    // 任意、Misskey の `report-abuse` に至っては投稿を渡す口が無い。
    // 「投稿だけが通報された」と読める文面にしない。
    final comment = await showReportCommentDialog(
      context,
      message:
          'この$postLabelを添えて '
          // ⚠ **bare username を出さない (#1012)。**リモートユーザーだと
          // 「@alice」としか出ず、同名の別サーバーのユーザーと区別が付かない
          // まま通報させることになる。組み立ての正本は [userAcct]。
          '@${userAcct(targetPost.author)} をサーバー管理者に通報しますか？',
    );
    if (comment == null) return;

    await _runVoidAction(
      messenger,
      () => (adapter as ReportSupport).reportPost(
        targetPost.id,
        targetPost.author.id,
        comment: comment.isNotEmpty ? comment : null,
      ),
      '通報しました',
    );
  }

  void _confirmDeleteAndRedraft(BuildContext context, Post targetPost) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    // 理由は [_confirmDelete] の同名コメント (#990 / #1009)。
    final timeline = readVisibleTimelines(ref);
    final postLabel = ref.read(postLabelProvider);

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('削除して再編集'),
        content: Text('$postLabelを削除し、内容を再編集します。この操作は取り消せません。'),
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
                timeline.removePost(targetPost.id);
                if (mounted) setState(() => _deletedPostId = targetPost.id);
                if (context.mounted) _popIfInThread(context);
                if (mounted) {
                  router.push('/compose', extra: {'redraft': targetPost});
                }
              }, '$postLabelを削除しました');
            },
            child: Text(
              '削除して再編集',
              style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 投稿本文中のカスタム絵文字をタップしたときに表示するアクションメニュー (#310)。
  /// ショートコードのコピーは全環境共通、リアクションは ReactionSupport 持ち
  /// (Misskey) の adapter のみ表示する。BottomSheet 自体は #396 で共通化。
  void _showEmojiActionMenu(
    BuildContext context,
    String shortcode,
    String emojiUrl,
  ) {
    final account = ref.read(currentAccountProvider);
    final adapter = account?.adapter;
    final targetPost = post.reblog ?? post;
    final messenger = ScaffoldMessenger.of(context);

    // シートを開く前に捕まえる (#990)。`_showEmojiPicker` と同じ理由。
    final timeline = readVisibleTimelines(ref);

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
              timeline: timeline,
            )
          : null,
    );
  }

  void _showEmojiPicker(BuildContext context) {
    // ⚠ アクションシートの項目から呼ばれる経路がある (#990 followup)。シートを
    // 開いている間にこのタイルが dispose されていると、下の `ref.read` が同期的に
    // 投げて**ピッカーがそもそも開かない**（unhandled で Sentry にも乗る）。
    //
    // シート経由は [_dispatchFromSheet] でも止まる (#996) が、この判定は残す。
    // #990 の時点でここだけに入れて残り 6 経路を取りこぼしたので、**ガードは
    // 呼ばれる側にも置いておく**（呼び出し口が増えても一緒に移動する）。
    if (!mounted) return;
    final account = ref.read(currentAccountProvider);
    final adapter = account?.adapter;
    if (adapter is! ReactionSupport) return;

    final targetPost = post.reblog ?? post;
    final messenger = ScaffoldMessenger.of(context);
    final backend = adapter as BackendAdapter;
    final reaction = adapter as ReactionSupport;
    // ⚠ **シートを開く前に捕まえる** (#990)。onSelected はシートを pop した後に
    // 走るので、その間に背後の TL が更新されてこのタイルが dispose されていると、
    // 実行時の `readVisibleTimelines(ref)` が StateError を投げていた。しかも
    // その呼び出しは `addReaction` より前にあったため、リアクションが送信され
    // ないまま成功も失敗も出ずに消えていた（Sentry CAPSICUM-4N）。
    final timeline = readVisibleTimelines(ref);

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
          timeline: timeline,
        ),
      ),
    );
  }

  /// 実行と失敗の扱いは [PostActionRunner] に寄せた (#943)。以前はこの 4 本が
  /// `post_touch_action_row` / `notification_tile` にも同名・同構造で並んでおり、
  /// 片方だけ直して母数が欠ける事故を繰り返していた。
  PostActionRunner _runner(
    ScaffoldMessengerState messenger, {
    VisibleTimelineMutator? timeline,
  }) => PostActionRunner(
    ref: ref,
    messenger: messenger,
    timeline: timeline,
    onPostUpdated: widget.onPostUpdated,
    onActionCompleted: onActionCompleted,
  );

  /// [timeline] は、シート等で await をまたぐ導線が**開く前に**捕まえたもの
  /// (#990)。渡さなければ実行時に取りにいく。
  Future<void> _runReactionAction(
    ScaffoldMessengerState messenger,
    BackendAdapter adapter,
    String postId,
    Future<void> Function() action,
    String successMessage, {
    String phase = ReactionPhase.add,
    VisibleTimelineMutator? timeline,
  }) => _runner(
    messenger,
    timeline: timeline,
  ).runReaction(adapter, postId, action, successMessage, phase: phase);

  Future<void> _runAction(
    ScaffoldMessengerState messenger,
    Future<Post> Function() action,
    String successMessage,
  ) => _runner(messenger).run(action, successMessage);

  Future<void> _runVoidAction(
    ScaffoldMessengerState messenger,
    Future<void> Function() action,
    String successMessage,
  ) => _runner(messenger).runVoid(action, successMessage);

  /// スレッド画面（/post）にいる場合、タイムラインに戻る。
  void _popIfInThread(BuildContext context) {
    if (!mounted || !context.mounted) return;
    final location = GoRouterState.of(context).uri.path;
    if (location == '/post') {
      context.pop();
    }
  }

  static final _nowPlayingPattern = RegExp(r'nowplaying', caseSensitive: false);

  bool _hasNowPlayingTag(Post post) {
    final content = post.content;
    if (content == null) return false;
    return _nowPlayingPattern.hasMatch(content);
  }

  /// 「削除してタグづけ」を表示してよいか。連合 TL に載らない投稿
  /// (unlisted / private / direct / channel / localOnly) はタグづけの
  /// 意味がないので除外する (#383)。
  bool _canRetag(Post post) =>
      post.scope == PostScope.public &&
      post.channelId == null &&
      !post.localOnly;

  void _confirmDeleteNowPlaying(BuildContext context, Post targetPost) {
    final account = ref.read(currentAccountProvider);
    final mulukhiya = account?.mulukhiya;
    if (account == null || mulukhiya == null) return;
    final messenger = ScaffoldMessenger.of(context);
    // 理由は [_confirmDelete] の同名コメント (#990)。
    final timeline = readVisibleTimelines(ref);
    // ⚠ **ダイアログを開く前に確定させる (#1009)。**失敗文言の組み立ては
    // ダイアログを閉じたあとに走るので、そこで `ref` を読むと dispose 済みの
    // タイルで StateError になる。
    final reblogLabel = ref.read(reblogLabelProvider);

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('NowPlaying を削除'),
        content: const Text('この投稿の NowPlaying 情報を除去して再投稿します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              mulukhiya
                  .deleteNowPlaying(
                    accessToken: account.userSecret.accessToken,
                    id: targetPost.id,
                  )
                  .then((_) {
                    timeline.removePost(targetPost.id);
                    if (mounted) setState(() => _deletedPostId = targetPost.id);
                    if (context.mounted) _popIfInThread(context);
                    messenger.showSnackBar(
                      const SnackBar(content: Text('NowPlaying を削除しました')),
                    );
                  })
                  .catchError((Object e, StackTrace st) {
                    unawaited(
                      Sentry.captureException(
                        scrubException(e),
                        stackTrace: st,
                        withScope: (scope) =>
                            scope.setTag('phase', 'post_action'),
                      ),
                    );
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          describePostActionError(e, reblogLabel: reblogLabel),
                        ),
                      ),
                    );
                  });
            },
            child: const Text('削除'),
          ),
        ],
      ),
    );
  }

  void _showRetagSheet(BuildContext context, Post targetPost) {
    final account = ref.read(currentAccountProvider);
    final mulukhiya = account?.mulukhiya;
    if (account == null || mulukhiya == null) return;

    final retagContent = targetPost.content ?? '';
    final retagIsHtml = targetPost.isHtml;
    final parsed = retagIsHtml
        ? extractTrailingTagsHtml(retagContent)
        : extractTrailingTagsMfm(retagContent);
    final messenger = ScaffoldMessenger.of(context);
    final adapter = ref.read(currentAdapterProvider);
    // ⚠ **シートを開く前に捕まえる** (#990)。⚠ **このシートがいちばん危ない** —
    // タグを編集する間ずっと開いており、その間に背後の TL が更新されてタイルが
    // dispose される窓が広い。onSubmit は pop より前に走り、解決が
    // `updateStatusTags` より**前**にあるので、投げると**タグづけが送信されない
    // まま無言で消える**。タグ管理は capsicum の根幹機能 (docs/CLAUDE.md)。
    final timeline = readVisibleTimelines(ref);
    // ラベルも同じ理由で開く前に確定させる (#1009)。builder の中に置くと、
    // 入力欄でキーボードが開いた再ビルドのときに dispose 済みで投げる。
    final postLabel = ref.read(postLabelProvider);
    // 失敗文言の組み立てに使う (#1027-C2)。onSubmit は上の窓の中で走るので、
    // ここも開く前に確定させる。
    final reblogLabel = ref.read(reblogLabelProvider);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RetagSheet(
        initialTags: parsed.trailingTags,
        mulukhiya: mulukhiya,
        adapter: adapter!,
        postLabel: postLabel,
        onSubmit: (tags) async {
          try {
            final raw = await mulukhiya.updateStatusTags(
              accessToken: account.userSecret.accessToken,
              id: targetPost.id,
              tags: tags,
            );
            timeline.removePost(targetPost.id);
            // 再投稿はモロヘイヤがサーバー側で行うので、capsicum は新しい id を
            // 知らない。レスポンスに完全な投稿が入っているので、それを「削除して
            // 再編集」と同じ楽観挿入に乗せる。これが無いとライブ更新 OFF や
            // スクロール中は streaming 待ちになる (#909 / #887 の残り)。
            if (raw != null && adapter is MulukhiyaRepostSupport) {
              final reposted = (adapter as MulukhiyaRepostSupport)
                  .parseRepostedPost(raw);
              if (reposted != null) timeline.insertOwnPost(reposted);
            }
            if (mounted) setState(() => _deletedPostId = targetPost.id);
            if (context.mounted) _popIfInThread(context);
            messenger.showSnackBar(const SnackBar(content: Text('タグを変更しました')));
          } catch (e, st) {
            unawaited(
              Sentry.captureException(
                scrubException(e),
                stackTrace: st,
                withScope: (scope) => scope.setTag('phase', 'post_action'),
              ),
            );
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  describePostActionError(e, reblogLabel: reblogLabel),
                ),
              ),
            );
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

  /// グループ（AP Group アクター）が Announce した投稿のリブログヘッダー (#811)。
  /// 通常の「X がブースト」と区別し、グループアイコン＋「〇〇 グループに投稿」を出す。
  /// タップでグループのプロフィール（＝Announce 済み投稿が並ぶ実質グループ TL）へ
  /// 遷移する。タイル本体の onTap（/post 遷移）より内側の GestureDetector が優先。
  Widget _buildGroupReblogHeader(BuildContext context, Post post) {
    final style = Theme.of(context).textTheme.bodySmall;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.push('/profile', extra: post.author),
      child: Row(
        children: [
          Icon(Icons.groups, size: 14, color: style?.color),
          const SizedBox(width: 4),
          Flexible(
            child: EmojiText(
              '${post.author.displayName ?? post.author.username} グループに投稿',
              emojis: post.author.emojis,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              fallbackHost: post.emojiHost,
            ),
          ),
        ],
      ),
    );
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

  IconData _scopeIcon(PostScope scope) =>
      postScopeIcon(scope, ref.read(currentAdapterProvider));

  String _scopeLabel(PostScope scope) =>
      postScopeLabel(scope, ref.read(currentAdapterProvider));

  /// 相対日時表示のときだけ、ホバー用の絶対日時文字列を返す（#754）。
  /// 既に絶対日時を表示している場合はツールチップ不要なので null。
  String? _absoluteTimeTooltip(DateTime postedAt) {
    if (ref.watch(absoluteTimeProvider)) return null;
    return formatAbsoluteTime(postedAt);
  }

  /// デスクトップでのみ [child] をツールチップで包む（#753 / #754）。
  /// モバイルは投稿の長押しでアクションシートを出すため、Tooltip の長押し
  /// 起動と競合させない。[message] が null/空のときも素の [child] を返す。
  Widget _maybeDesktopTooltip(String? message, Widget child) {
    if (!isDesktop || message == null || message.isEmpty) return child;
    return Tooltip(message: message, child: child);
  }
}

/// カウントチップのホバープレビュー対象の種別 (#856)。API で「誰がやったか」を
/// 取得できるものだけ。返信・引用は該当 API が無いので対象外（hover 無し）。
enum _CountHoverKind { reblog, favourite }

class _CountChip extends ConsumerStatefulWidget {
  final IconData icon;
  final String label;
  final int count;
  final VoidCallback? onTap;

  /// ホバーで「誰がやったか」プレビューを出す場合の対象投稿と種別 (#856)。
  /// null のチップ（返信・引用など）はホバーしない。
  final Post? hoverPost;
  final _CountHoverKind? hoverKind;

  const _CountChip({
    required this.icon,
    required this.label,
    required this.count,
    this.onTap,
    this.hoverPost,
    this.hoverKind,
  });

  @override
  ConsumerState<_CountChip> createState() => _CountChipState();
}

class _CountChipState extends ConsumerState<_CountChip>
    with _HoverUsersOverlay {
  @override
  void dispose() {
    disposeHover();
    super.dispose();
  }

  @override
  Future<List<User>>? hoverFetch() {
    final post = widget.hoverPost;
    final kind = widget.hoverKind;
    if (post == null || kind == null) return null;
    final adapter = ref.read(currentAdapterProvider);
    const q = TimelineQuery(limit: _HoverUsersOverlay.hoverMaxAvatars + 1);
    switch (kind) {
      case _CountHoverKind.reblog:
        if (adapter is MastodonAdapter) {
          return adapter.getRebloggedBy(post.id, query: q).then((r) => r.users);
        }
        if (adapter is MisskeyAdapter) {
          return adapter.getRenotedBy(post.id, query: q).then((r) => r.users);
        }
        return null;
      case _CountHoverKind.favourite:
        if (adapter is MastodonAdapter) {
          return adapter
              .getFavouritedBy(post.id, query: q)
              .then((r) => r.users);
        }
        if (adapter is MisskeyAdapter) {
          return adapter.getReactedBy(post.id, query: q).then((r) => r.users);
        }
        return null;
    }
  }

  @override
  String get hoverCacheKey =>
      '${widget.hoverPost?.id} __${widget.hoverKind?.name}';

  @override
  int get hoverTotalCount => widget.count;

  @override
  String? get hoverFallbackHost => widget.hoverPost?.author.host;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final color = style?.color;
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(widget.icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text('${widget.label} ${widget.count}', style: style),
      ],
    );
    final Widget result = widget.onTap != null
        ? InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
              child: child,
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
            child: child,
          );
    // ホバーで「誰がやったか」プレビュー (#856)。対象種別のあるチップのみ。
    if (widget.hoverKind == null) return result;
    return MouseRegion(
      onEnter: (_) => hoverEnter(),
      onExit: (_) => hoverExit(),
      child: result,
    );
  }
}

/// 短時間に同じリアクションへ繰り返しホバーしても API を叩き直さないための
/// インメモリキャッシュ。key は `noteId reactionKey`。
class _ReactionUsersCache {
  static final Map<String, List<User>> _cache = {};

  static List<User>? get(String key) => _cache[key];

  static void put(String key, List<User> users) {
    if (_cache.length > 200) _cache.clear();
    _cache[key] = users;
  }
}

/// リアクション / ブースト / お気に入り等のチップにポインタを合わせたとき、
/// 「誰がやったか」のアバターをオーバーレイ表示する共通機構 (#575 / #856)。
///
/// ホスト State は [hoverFetch]（未対応なら null を返す）/ [hoverCacheKey] /
/// [hoverTotalCount] / [hoverFallbackHost] を実装し、build の [MouseRegion] で
/// [hoverEnter] / [hoverExit] を、dispose で [disposeHover] を呼ぶ。表示可否は
/// [userHoverPopupProvider] トグルで制御し、キャッシュは [_ReactionUsersCache]
/// を共有する。ポインタ環境でのみ発火するためプラットフォーム分岐は不要。
mixin _HoverUsersOverlay<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  static const _hoverDelay = Duration(milliseconds: 350);
  static const hoverMaxAvatars = 10;

  Timer? _hoverTimer;
  OverlayEntry? _overlay;
  bool _loading = false;
  bool _failed = false;
  bool _fetching = false;
  List<User>? _users;

  /// 「誰がやったか」を取得する。未対応 adapter 等では null を返してホバーを
  /// 無効化する。delay 経過後に一度だけ呼ばれる。
  Future<List<User>>? hoverFetch();
  String get hoverCacheKey;
  int get hoverTotalCount;
  String? get hoverFallbackHost;

  void hoverEnter() {
    if (!ref.read(userHoverPopupProvider)) return;
    _hoverTimer?.cancel();
    _hoverTimer = Timer(_hoverDelay, _showHoverOverlay);
  }

  void hoverExit() {
    _hoverTimer?.cancel();
    _removeHoverOverlay();
  }

  void disposeHover() {
    _hoverTimer?.cancel();
    _removeHoverOverlay();
  }

  Future<void> _showHoverOverlay() async {
    if (!mounted) return;
    final cached = _ReactionUsersCache.get(hoverCacheKey);
    if (cached != null) {
      _users = cached;
      _failed = false;
      _loading = false;
      _insertHoverOverlay();
      return;
    }
    // 飛行中の再ホバー: ローディング表示だけ出し直して、**2 本目は発射しない**。
    // [hoverFetch] は呼んだ時点でリクエストが出るので、この判定を後ろに置くと
    // 離脱→再ホバーのたびに誰も await しない future が生まれる。ハンドラが付いて
    // いないため、回線断や 5xx で落ちると unhandled async error としてゾーンへ
    // 抜け、Sentry の crash-free rate を汚す。[hoverExit] は飛行中の取得を止め
    // ないので、この経路は普通のマウス操作で踏める。
    // ここで挿し直したオーバーレイは、先行の取得が終わったときの
    // `_overlay?.markNeedsBuild()` で中身が入る。
    if (_fetching) {
      _loading = true;
      _failed = false;
      _insertHoverOverlay();
      return;
    }
    // 未キャッシュ: fetcher が無ければ（非対応 adapter 等）何も出さない。
    final future = hoverFetch();
    if (future == null) return;
    // await をまたぐ間に、この State が別の投稿へ再利用されうる。PostTile は
    // リストで key を持たないため、ライブ更新で TL の先頭に投稿が入ると
    // [_CountChipState] が別の投稿を描画する。[hoverCacheKey] は現在の投稿から
    // 都度組み立てられるので、await 明けに読み直すと **投稿 A の結果が投稿 B の
    // キーで static キャッシュに入る**。[_ReactionUsersCache] は 200 件残るため、
    // 以後 B をホバーするたびに A のブースト者が出続ける (#920)。
    final requestedKey = hoverCacheKey;
    _loading = true;
    _failed = false;
    _insertHoverOverlay();
    _fetching = true;
    try {
      final users = await future;
      _ReactionUsersCache.put(requestedKey, users);
      if (!mounted) return;
      if (hoverCacheKey != requestedKey) {
        _discardStaleHover();
        return;
      }
      _users = users;
      _loading = false;
    } catch (_) {
      if (!mounted) return;
      if (hoverCacheKey != requestedKey) {
        _discardStaleHover();
        return;
      }
      _failed = true;
      _loading = false;
    } finally {
      _fetching = false;
    }
    // オーバーレイがまだ表示中なら内容を更新。
    _overlay?.markNeedsBuild();
  }

  /// await 明けに別の投稿の State になっていたときの後始末。取得結果は元の
  /// キーでキャッシュ済みなので捨ててよい。ローディング表示のまま放置すると
  /// スピナーが回りっぱなしになるので、オーバーレイごと畳む（ポインタが載った
  /// ままなら、いったん外して入れ直せば現在の投稿として取り直される）。
  void _discardStaleHover() {
    _loading = false;
    _failed = false;
    _users = null;
    _removeHoverOverlay();
  }

  void _insertHoverOverlay() {
    if (_overlay != null) {
      _overlay!.markNeedsBuild();
      return;
    }
    final overlayState = Overlay.maybeOf(context);
    if (overlayState == null) return;
    _overlay = OverlayEntry(builder: _buildHoverOverlay);
    overlayState.insert(_overlay!);
  }

  void _removeHoverOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  Widget _buildHoverOverlay(BuildContext overlayContext) {
    final box = context.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null || !box.attached) {
      return const SizedBox.shrink();
    }
    final chipOffset = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final chipSize = box.size;
    final overlaySize = overlayBox.size;
    const overlayWidth = 220.0;
    const margin = 8.0;
    var left = chipOffset.dx;
    if (left + overlayWidth + margin > overlaySize.width) {
      left = overlaySize.width - overlayWidth - margin;
    }
    if (left < margin) left = margin;
    // チップの上に出す。上端に余裕がなければ下に出す。
    final showAbove = chipOffset.dy > 160;
    return Positioned(
      left: left,
      top: showAbove ? null : chipOffset.dy + chipSize.height + 4,
      bottom: showAbove ? overlaySize.height - chipOffset.dy + 4 : null,
      width: overlayWidth,
      child: IgnorePointer(
        child: _ReactionUsersTooltip(
          loading: _loading,
          failed: _failed,
          users: _users ?? const [],
          totalCount: hoverTotalCount,
          maxAvatars: hoverMaxAvatars,
          fallbackHost: hoverFallbackHost,
        ),
      ),
    );
  }
}

class _ReactionChips extends StatelessWidget {
  final Post post;
  final ValueChanged<String> onToggle;

  const _ReactionChips({required this.post, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: post.reactions.entries.map((entry) {
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
          return _ReactionChip(
            post: post,
            reactionKey: entry.key,
            count: entry.value,
            isMyReaction: post.myReaction == entry.key,
            emojiUrl: emojiUrl,
            onToggle: onToggle,
          );
        }).toList(),
      ),
    );
  }
}

/// 単一のリアクションチップ。ポインタ環境（デスクトップや iPad + マウス等）
/// ではホバーで「誰がこのリアクションをしたか」をオーバーレイ表示する (#575)。
/// タッチ環境では [MouseRegion] のホバーイベントが発火しないため、プラット
/// フォームや画面幅による出し分けは不要。
class _ReactionChip extends ConsumerStatefulWidget {
  final Post post;
  final String reactionKey;
  final int count;
  final bool isMyReaction;
  final String? emojiUrl;
  final ValueChanged<String> onToggle;

  const _ReactionChip({
    required this.post,
    required this.reactionKey,
    required this.count,
    required this.isMyReaction,
    required this.emojiUrl,
    required this.onToggle,
  });

  @override
  ConsumerState<_ReactionChip> createState() => _ReactionChipState();
}

class _ReactionChipState extends ConsumerState<_ReactionChip>
    with _HoverUsersOverlay {
  @override
  void dispose() {
    disposeHover();
    super.dispose();
  }

  // #575: 「誰がこのリアクションをしたか」のホバー表示。取得できるのは
  // Misskey のみ（getReactedBy を絵文字 type で絞る）。
  @override
  Future<List<User>>? hoverFetch() {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! MisskeyAdapter) return null;
    return adapter
        .getReactedBy(
          widget.post.id,
          type: widget.reactionKey,
          query: const TimelineQuery(
            limit: _HoverUsersOverlay.hoverMaxAvatars + 1,
          ),
        )
        .then((r) => r.users);
  }

  @override
  String get hoverCacheKey => '${widget.post.id} ${widget.reactionKey}';

  @override
  int get hoverTotalCount => widget.count;

  @override
  String? get hoverFallbackHost =>
      widget.post.emojiHost ?? widget.post.author.host;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // リアクションチップの絵文字にもカスタム絵文字サイズ設定を反映する (#852)。
    final emojiSize = ref.watch(emojiSizeProvider);
    return MouseRegion(
      onEnter: (_) => hoverEnter(),
      onExit: (_) => hoverExit(),
      // 長押し（タッチ）/ 右クリック（デスクトップ）でドロップダウンメニュー
      // を出す (#851)。タップ（onPressed）のトグル操作は従来どおり変更しない。
      child: GestureDetector(
        onLongPress: () => _showChipMenu(context),
        onSecondaryTap: () => _showChipMenu(context),
        child: ActionChip(
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          side: widget.isMyReaction
              ? BorderSide(color: theme.colorScheme.primary)
              : null,
          backgroundColor: widget.isMyReaction
              ? theme.colorScheme.primaryContainer
              : null,
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.emojiUrl != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  // 横長絵文字は高さの 3 倍で頭打ちにする。**本文の EmojiText は
                  // #858 で固定倍率 cap を撤廃したが、リアクションチップは肥大化
                  // 防止でこの 3x cap を意図的に維持する**（本文と別方針・#924）。
                  // 撤廃するとチップが横に伸びて行が崩れるので消さないこと。
                  //
                  // ⚠ **デコード前の幅を予約するのは本文以上に重要** (#1032)。
                  // チップは `_ReactionChips` の `Wrap` に並ぶので、幅が 0 のまま
                  // レイアウトされると少ない行数に詰まり、デコード後に**行ごと**
                  // 増えてタイルの高さが飛ぶ。本文の折り返し 1 行より変動が大きい。
                  // アスペクト比のキャッシュは本文と共有なので、本文で一度出た
                  // 絵文字はチップでも初回から正しい幅になる。
                  child: InlineCustomEmoji(
                    url: widget.emojiUrl!,
                    shortcode: widget.reactionKey,
                    size: emojiSize,
                    maxWidthFactor: 3,
                    fallback: Text(
                      widget.reactionKey,
                      style: TextStyle(
                        fontSize:
                            emojiSize * AppConstants.emojiFallbackTextScale,
                      ),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Image.network(
                    AppConstants.twemojiUrl(widget.reactionKey),
                    width: emojiSize,
                    height: emojiSize,
                    errorBuilder: (_, _, _) => Text(
                      widget.reactionKey,
                      style: TextStyle(
                        fontSize:
                            emojiSize * AppConstants.emojiFallbackTextScale,
                      ),
                    ),
                  ),
                ),
              Text('${widget.count}', style: theme.textTheme.labelSmall),
            ],
          ),
          onPressed: () => widget.onToggle(widget.reactionKey),
        ),
      ),
    );
  }

  /// 長押し / 右クリックで出すリアクションチップのメニュー (#851)。
  /// リアクションの付与・解除、ショートコードのコピー、リアクションした人の
  /// 一覧（Misskey のみ）を含む。タップのトグルはこのメニューと独立。
  Future<void> _showChipMenu(BuildContext context) async {
    final adapter = ref.read(currentAdapterProvider);
    final messenger = ScaffoldMessenger.of(context);
    final copyText = _copyText;
    final canReact = adapter is ReactionSupport;
    // 「リアクションした人」を取得できるのは Misskey のみ（getReactedBy）。
    final reactorsAdapter = adapter is MisskeyAdapter ? adapter : null;

    await showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canReact)
              ListTile(
                leading: Icon(
                  widget.isMyReaction
                      ? Icons.remove_circle_outline
                      : Icons.add_reaction_outlined,
                ),
                title: Text(
                  widget.isMyReaction ? 'リアクションを取り消す' : 'このリアクションを付ける',
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  widget.onToggle(widget.reactionKey);
                },
              ),
            ListTile(
              leading: const Icon(Icons.content_copy_outlined),
              title: const Text('ショートコードをコピー'),
              subtitle: Text(copyText),
              onTap: () {
                Navigator.pop(sheetContext);
                Clipboard.setData(ClipboardData(text: copyText));
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('ショートコードをコピーしました'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
            if (reactorsAdapter != null)
              ListTile(
                leading: const Icon(Icons.people_outline),
                title: const Text('リアクションした人'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showReactedBy(context, reactorsAdapter);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// リアクションチップの「リアクションした人」一覧を [UserListScreen]（/users）
  /// で開く。この絵文字に限定するため getReactedBy に type を渡す。
  void _showReactedBy(BuildContext context, MisskeyAdapter adapter) {
    context.push(
      '/users',
      extra: {
        'title': 'リアクション',
        'fetcher': (String? cursor) => adapter.getReactedBy(
          widget.post.id,
          type: widget.reactionKey,
          query: TimelineQuery(maxId: cursor, limit: 20),
        ),
      },
    );
  }

  /// コピー用ショートコード文字列。カスタム絵文字はローカル（`@.`）なら
  /// `:name:`、リモートは `:name@host:`。Unicode 絵文字はその文字自体。
  String get _copyText {
    final k = widget.reactionKey;
    if (!(k.startsWith(':') && k.endsWith(':'))) return k;
    final inner = k.substring(1, k.length - 1);
    final at = inner.indexOf('@');
    if (at < 0) return ':$inner:';
    final name = inner.substring(0, at);
    final host = inner.substring(at + 1);
    if (host == '.' || host.isEmpty) return ':$name:';
    return ':$name@$host:';
  }
}

/// ホバー時に表示する「リアクションした人」一覧の中身。
class _ReactionUsersTooltip extends StatelessWidget {
  final bool loading;
  final bool failed;
  final List<User> users;
  final int totalCount;
  final int maxAvatars;
  final String? fallbackHost;

  const _ReactionUsersTooltip({
    required this.loading,
    required this.failed,
    required this.users,
    required this.totalCount,
    required this.maxAvatars,
    required this.fallbackHost,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget body;
    if (loading) {
      body = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('読み込み中…', style: theme.textTheme.bodySmall),
        ],
      );
    } else if (failed) {
      body = Text('取得できませんでした', style: theme.textTheme.bodySmall);
    } else if (users.isEmpty) {
      body = Text('リアクションした人はいません', style: theme.textTheme.bodySmall);
    } else {
      final shown = users.take(maxAvatars).toList();
      final remaining = totalCount - shown.length;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final user in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  UserAvatar(user: user, size: 20, compact: true),
                  const SizedBox(width: 6),
                  Flexible(
                    child: EmojiText(
                      user.displayName?.isNotEmpty == true
                          ? user.displayName!
                          : user.username,
                      emojis: user.emojis,
                      // Misskey の /notes/reactions・/notes/renotes は reactor の
                      // emojis を空で返すため、名前の :emoji: は fallbackHost で
                      // 解決する。ローカル reactor は現在ホストで解決できるが、
                      // リモート reactor の名前絵文字は現在ホストの /emoji/name.webp
                      // に無く 404 → shortcode がそのまま出ていた (#856)。reactor
                      // 自身の host で解決する（ローカルは現在ホスト＝従来どおり）。
                      fallbackHost: user.host ?? fallbackHost,
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          if (remaining > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('ほか $remaining 人', style: theme.textTheme.bodySmall),
            ),
        ],
      );
    }

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: body,
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
      debugLogException('Poll vote error', e);
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
      debugLogException('Poll vote onActionCompleted error', e);
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

class _QuoteCard extends StatefulWidget {
  final Post quote;

  const _QuoteCard({required this.quote});

  @override
  State<_QuoteCard> createState() => _QuoteCardState();
}

class _QuoteCardState extends State<_QuoteCard> {
  bool _cwExpanded = false;

  Post get quote => widget.quote;

  @override
  void didUpdateWidget(covariant _QuoteCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.quote.id != widget.quote.id) {
      _cwExpanded = false;
    }
  }

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
            if (quote.spoilerText != null && quote.spoilerText!.isNotEmpty) ...[
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => setState(() => _cwExpanded = !_cwExpanded),
                child: Row(
                  children: [
                    Icon(
                      _cwExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 14,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                    const SizedBox(width: 2),
                    Expanded(
                      child: EmojiText(
                        quote.spoilerText!,
                        emojis: quote.emojis,
                        fallbackHost: quote.emojiHost,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if ((quote.spoilerText == null ||
                    quote.spoilerText!.isEmpty ||
                    _cwExpanded) &&
                quote.content != null &&
                quote.content!.isNotEmpty) ...[
              const SizedBox(height: 4),
              EmojiText(
                _stripHtml(quote.content!),
                emojis: quote.emojis,
                fallbackHost: quote.emojiHost,
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

class _AttachmentThumbnails extends ConsumerStatefulWidget {
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
  ConsumerState<_AttachmentThumbnails> createState() =>
      _AttachmentThumbnailsState();
}

class _AttachmentThumbnailsState extends ConsumerState<_AttachmentThumbnails> {
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
    final thumbScale = ref.watch(thumbnailScaleProvider);
    if (images.length == 1) {
      // 1 枚でも固定高さの横長枠に cover で収める (#718)。2 枚 (= 160) や
      // 3 枚以上 (各行 ≈ 158) と同じ高さに揃え、枚数・向きを問わずサムネ
      // 高さを統一する。従来は 1 枚だけ contain で縦長が縦に伸びていた。
      return SizedBox(
        height: 160 * thumbScale,
        width: double.infinity,
        child: _buildThumbnail(context, images.first, 0, images),
      );
    }

    if (images.length == 2) {
      return SizedBox(
        height: 160 * thumbScale,
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
      height: 320 * thumbScale,
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
    final blurAll = ref.watch(blurAllImagesProvider);
    final isSensitive = (widget.sensitive || blurAll) && !_revealed;
    // 動画系 (video / gifv) で preview_url が無い場合は実 URL (.mp4 等) を
    // Image.network に渡しても Skia が aspect だけ取って黒フレームを返し
    // (broken_image にも落ちず無言で黒くなる)、ユーザーには「画像が消えた」
    // ように見える。Image を試みず placeholder を返す。
    // 報告経路は Linux GTK (#491) だが、原因は preview_url 不在時のデコード
    // 動作という プラットフォーム非依存の不変条件のため、全環境で同じ防御を
    // かける。
    final hasPreview = attachment.previewUrl != null;
    final isVideoLike =
        attachment.type == AttachmentType.video ||
        attachment.type == AttachmentType.gifv;
    final imageUrl = attachment.previewUrl ?? attachment.url;

    Widget media;
    if (isVideoLike && !hasPreview) {
      media = Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      );
    } else {
      media = Image.network(
        imageUrl,
        fit: fit,
        errorBuilder: (_, _, _) => Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Icon(Icons.broken_image_outlined),
        ),
      );
    }
    // sensitive 時のみ ImageFiltered で blur を掛ける。非 sensitive 時に
    // identity (no-op) の filter を被せても render が黒に落ちる事例があり
    // (Linux GTK で確認、#491)、no-op の filter は実害だけ残るため外す。
    if (isSensitive) {
      media = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: media,
      );
    }

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
            media,
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
  final DecentralizedBackendAdapter adapter;
  final String postLabel;
  final Future<void> Function(List<String> tags) onSubmit;

  const _RetagSheet({
    required this.initialTags,
    required this.mulukhiya,
    required this.adapter,
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
  List<FavoriteTag> _favoriteTags = [];
  List<String> _suggestions = [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _tags = List.of(widget.initialTags);
    _loadDefaultTags();
    _loadFavoriteTags();
    _controller.addListener(_onTextChanged);
  }

  Future<void> _loadDefaultTags() async {
    final tags = await widget.mulukhiya.getDefaultHashtags();
    if (mounted) setState(() => _defaultTags = tags);
  }

  Future<void> _loadFavoriteTags() async {
    try {
      final tags = await widget.mulukhiya.getFavoriteTags();
      if (mounted) setState(() => _favoriteTags = tags);
    } catch (_) {}
  }

  void _onTextChanged() {
    // IME 変換中は setState を抑制（rebuild が EditableText の composition / selection を
    // 巻き戻す Flutter 上流症例の触媒になるため。#463 / #54 同型）
    if (_controller.value.composing.isValid) return;

    _debounce?.cancel();
    final query = _controller.text.trim().replaceAll('#', '');
    if (query.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _fetchSuggestions(query);
    });
  }

  Future<void> _fetchSuggestions(String query) async {
    final lowerQuery = query.toLowerCase();

    // Client-side filter on favorite tags.
    final fromFavorites = _favoriteTags
        .where((t) => t.name.toLowerCase().contains(lowerQuery))
        .map((t) => t.name)
        .toList();

    // Remote search via SNS API.
    List<String> fromSearch = [];
    final adapter = widget.adapter;
    if (adapter is SearchSupport) {
      try {
        fromSearch = await (adapter as SearchSupport).searchHashtags(
          query,
          limit: 5,
        );
      } catch (_) {}
    }

    if (!mounted) return;

    // Merge: favorites first, then remote results, deduplicated.
    final seen = <String>{..._tags};
    final merged = <String>[];
    for (final tag in [...fromFavorites, ...fromSearch]) {
      if (seen.add(tag)) merged.add(tag);
    }

    setState(() => _suggestions = merged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  void _addTag() {
    final text = _controller.text.trim().replaceAll('#', '');
    if (text.isEmpty || _tags.contains(text)) return;
    setState(() => _tags.add(text));
    _controller.clear();
  }

  void _addSuggestedTag(String tag) {
    if (_tags.contains(tag)) return;
    setState(() => _tags.add(tag));
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
      builder: (context, scrollController) => SingleChildScrollView(
        controller: scrollController,
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
            Wrap(
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
            if (_suggestions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SizedBox(
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _suggestions.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 4),
                    itemBuilder: (context, index) {
                      final tag = _suggestions[index];
                      return ActionChip(
                        avatar: const Icon(Icons.tag, size: 18),
                        label: Text('#$tag', overflow: TextOverflow.ellipsis),
                        onPressed: () => _addSuggestedTag(tag),
                      );
                    },
                  ),
                ),
              ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submitting
                    ? null
                    : () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('削除してタグづけ'),
                            content: Text(
                              '元の${widget.postLabel}を削除し、タグを変更して再${widget.postLabel}します。この操作は取り消せません。',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, false),
                                child: const Text('キャンセル'),
                              ),
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, true),
                                child: const Text('実行'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed != true) return;
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

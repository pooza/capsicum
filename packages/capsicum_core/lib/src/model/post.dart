import 'attachment.dart';
import 'poll.dart';
import 'post_scope.dart';
import 'preview_card.dart';
import 'user.dart';

enum QuoteState { pending, accepted, rejected, deleted, unauthorized }

/// 投稿ごとのリアクション受付条件（Misskey の `reactionAcceptance`）。#1044
///
/// ⚠ **サーバーは条件に合わないリアクションをエラーにせず ❤️ へ差し替える**
/// （`core/ReactionService.ts` の `FALLBACK = '❤'`）。成功扱いで返ってくるので
/// **クライアントからは失敗として観測できない**。ユーザーには「押し間違えた？」
/// に見えるため、送る前に出し分ける必要がある。
///
/// Mastodon には対応する概念が無いので、常に null になる。
enum ReactionAcceptance {
  /// 何を選んでも ❤️ になる。
  likeOnly,

  /// リアクションする側がリモートなら ❤️ になる。
  likeOnlyForRemote,

  /// センシティブなカスタム絵文字は ❤️ になる。
  nonSensitiveOnly,

  /// ローカルは [nonSensitiveOnly]、リモートは [likeOnly] 相当。
  nonSensitiveOnlyForLocalLikeOnlyForRemote,
}

class Post {
  final String id;
  final DateTime postedAt;
  final User author;
  final String? content;

  /// `content` が HTML（Mastodon）か MFM（Misskey）かを示す。
  /// バックエンドが確定的に持つ情報。本文表示側はこのフラグでレンダラを選ぶ
  /// （`<p>` 有無のヒューリスティックは Misskey 連合ノートで誤判定するため）。
  final bool isHtml;

  final PostScope scope;
  final List<Attachment> attachments;
  final int favouriteCount;
  final int reblogCount;
  final int replyCount;
  final int quoteCount;
  final bool favourited;
  final bool reblogged;
  final bool bookmarked;
  final bool sensitive;
  final Map<String, int> reactions;
  final String? myReaction;
  final Map<String, String> reactionEmojis;
  final String? inReplyToId;
  final Post? reblog;
  final Post? quote;
  final QuoteState? quoteState;
  final String? spoilerText;
  final Map<String, String> emojis;
  final String? emojiHost;
  final PreviewCard? card;
  final Poll? poll;
  final FilterAction? filterAction;
  final String? filterTitle;
  final bool pinned;
  final String? channelId;
  final String? channelName;
  final bool localOnly;
  final bool quotable;
  final String? language;
  final String? url;

  /// リアクションの受付条件 (#1044)。Misskey のみ。null は制限なし。
  final ReactionAcceptance? reactionAcceptance;

  const Post({
    required this.id,
    required this.postedAt,
    required this.author,
    this.content,
    this.isHtml = false,
    this.scope = PostScope.public,
    this.attachments = const [],
    this.favouriteCount = 0,
    this.reblogCount = 0,
    this.replyCount = 0,
    this.quoteCount = 0,
    this.favourited = false,
    this.reblogged = false,
    this.bookmarked = false,
    this.sensitive = false,
    this.reactions = const {},
    this.myReaction,
    this.reactionEmojis = const {},
    this.inReplyToId,
    this.reblog,
    this.quote,
    this.quoteState,
    this.spoilerText,
    this.emojis = const {},
    this.emojiHost,
    this.card,
    this.poll,
    this.filterAction,
    this.filterTitle,
    this.pinned = false,
    this.channelId,
    this.channelName,
    this.localOnly = false,
    this.quotable = true,
    this.language,
    this.url,
    this.reactionAcceptance,
  });

  /// 派生オブジェクトを生成する。enrich パイプライン（IsCatEnricher 等）の
  /// author / reblog 差し替え、添付説明（ALT）編集後の attachments 差し替え等で
  /// 使用。フィールド追加時の取りこぼし防止のため、新フィールドの追加はここに
  /// 追従する。
  Post copyWith({
    User? author,
    Post? reblog,
    bool? reblogged,
    int? reblogCount,
    List<Attachment>? attachments,
    bool? bookmarked,
  }) => Post(
    id: id,
    postedAt: postedAt,
    author: author ?? this.author,
    content: content,
    isHtml: isHtml,
    scope: scope,
    attachments: attachments ?? this.attachments,
    favouriteCount: favouriteCount,
    reblogCount: reblogCount ?? this.reblogCount,
    replyCount: replyCount,
    quoteCount: quoteCount,
    favourited: favourited,
    reblogged: reblogged ?? this.reblogged,
    bookmarked: bookmarked ?? this.bookmarked,
    sensitive: sensitive,
    reactions: reactions,
    myReaction: myReaction,
    reactionEmojis: reactionEmojis,
    inReplyToId: inReplyToId,
    reblog: reblog ?? this.reblog,
    quote: quote,
    quoteState: quoteState,
    spoilerText: spoilerText,
    emojis: emojis,
    emojiHost: emojiHost,
    card: card,
    poll: poll,
    filterAction: filterAction,
    filterTitle: filterTitle,
    pinned: pinned,
    channelId: channelId,
    channelName: channelName,
    localOnly: localOnly,
    quotable: quotable,
    language: language,
    url: url,
    reactionAcceptance: reactionAcceptance,
  );
}

enum FilterAction { hide, warn }

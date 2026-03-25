import 'attachment.dart';
import 'poll.dart';
import 'post_scope.dart';
import 'preview_card.dart';
import 'user.dart';

enum QuoteState { pending, accepted, rejected, deleted, unauthorized }

class Post {
  final String id;
  final DateTime postedAt;
  final User author;
  final String? content;
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

  const Post({
    required this.id,
    required this.postedAt,
    required this.author,
    this.content,
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
  });
}

enum FilterAction { hide, warn }

import 'attachment.dart';
import 'post_scope.dart';
import 'user.dart';

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
  final bool favourited;
  final bool reblogged;
  final bool bookmarked;
  final bool sensitive;
  final Map<String, int> reactions;
  final String? myReaction;
  final Map<String, String> reactionEmojis;
  final String? inReplyToId;
  final Post? reblog;
  final String? spoilerText;
  final Map<String, String> emojis;
  final String? emojiHost;
  final FilterAction? filterAction;
  final String? filterTitle;

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
    this.favourited = false,
    this.reblogged = false,
    this.bookmarked = false,
    this.sensitive = false,
    this.reactions = const {},
    this.myReaction,
    this.reactionEmojis = const {},
    this.inReplyToId,
    this.reblog,
    this.spoilerText,
    this.emojis = const {},
    this.emojiHost,
    this.filterAction,
    this.filterTitle,
  });
}

enum FilterAction { hide, warn }

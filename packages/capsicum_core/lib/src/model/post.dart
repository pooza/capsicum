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
  final String? inReplyToId;
  final Post? reblog;

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
    this.inReplyToId,
    this.reblog,
  });
}

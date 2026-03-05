import 'post_scope.dart';

class PostDraft {
  final String? content;
  final PostScope scope;
  final String? inReplyToId;
  final List<String> mediaIds;
  final String? spoilerText;
  final bool sensitive;

  const PostDraft({
    this.content,
    this.scope = PostScope.public,
    this.inReplyToId,
    this.mediaIds = const [],
    this.spoilerText,
    this.sensitive = false,
  });
}

import 'post_scope.dart';

class PostDraft {
  final String? content;
  final PostScope scope;
  final String? inReplyToId;
  final String? quoteId;
  final List<String> mediaIds;
  final String? spoilerText;
  final bool sensitive;
  final bool localOnly;
  final String? channelId;

  /// When true, adds X-Mulukhiya header to bypass mulukhiya hooks.
  final bool skipMulukhiya;

  /// When set, the post is scheduled for future publication.
  final DateTime? scheduledAt;

  /// ISO 639-1 language code for the post (Mastodon only).
  final String? language;

  const PostDraft({
    this.content,
    this.scope = PostScope.public,
    this.inReplyToId,
    this.quoteId,
    this.mediaIds = const [],
    this.spoilerText,
    this.sensitive = false,
    this.localOnly = false,
    this.channelId,
    this.skipMulukhiya = false,
    this.scheduledAt,
    this.language,
  });
}

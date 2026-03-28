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

  /// Poll options (choice texts). When non-null, a poll is attached.
  final List<String>? pollOptions;

  /// Poll expiration duration in seconds.
  final int? pollExpiresIn;

  /// Whether multiple choices are allowed.
  final bool pollMultiple;

  /// Hide vote totals until poll ends (Mastodon only).
  final bool pollHideTotals;

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
    this.pollOptions,
    this.pollExpiresIn,
    this.pollMultiple = false,
    this.pollHideTotals = false,
  });
}

import 'post_scope.dart';

class PostDraft {
  final String? content;
  final PostScope scope;
  final String? inReplyToId;
  final String? quoteId;
  final List<String> mediaIds;
  final String? spoilerText;
  final bool sensitive;

  /// [sensitive] の `false` を**明示的に送るか** (#1194)。
  ///
  /// ⚠⚠ **Mastodon は `sensitive` を省くとサーバー既定（`source.sensitive`）を
  /// 当てる。**したがって `false` を送らないと、**既定が true の利用者は capsicum
  /// から閲覧注意を外せない**（トグルが嘘になる）。
  ///
  /// ⚠ **常に送る形にはできない。**`source` を返さない / 既定を持たないサーバー
  /// では、いままで効いていた「サーバー既定に任せる」が壊れる。**既定を読めた
  /// ときだけ**明示する。
  ///
  /// ⚠ `true` のときは従来どおり常に送る（この旗に関わらず）。
  final bool sensitiveExplicit;
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

  /// Quote approval policy (Mastodon 4.5+).
  /// Values: 'public', 'followers', 'nobody'.
  final String? quoteApprovalPolicy;

  /// 指名（`specified`）の宛先のユーザー ID (#1161)。Misskey のみ。
  /// 空なら送らない。
  final List<String> visibleUserIds;

  const PostDraft({
    this.content,
    this.scope = PostScope.public,
    this.inReplyToId,
    this.quoteId,
    this.mediaIds = const [],
    this.spoilerText,
    this.sensitive = false,
    this.sensitiveExplicit = false,
    this.localOnly = false,
    this.channelId,
    this.skipMulukhiya = false,
    this.scheduledAt,
    this.language,
    this.pollOptions,
    this.pollExpiresIn,
    this.pollMultiple = false,
    this.pollHideTotals = false,
    this.quoteApprovalPolicy,
    this.visibleUserIds = const [],
  });
}

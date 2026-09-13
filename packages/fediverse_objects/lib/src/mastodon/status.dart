import 'package:json_annotation/json_annotation.dart';

import 'account.dart';
import 'media_attachment.dart';

part 'status.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonStatus {
  final String id;
  final DateTime createdAt;
  final MastodonAccount account;
  final String content;
  final String visibility;
  final int favouritesCount;
  final int reblogsCount;
  final int repliesCount;
  final bool? favourited;
  final bool? reblogged;
  final bool? bookmarked;
  final String? inReplyToId;
  final MastodonStatus? reblog;
  @JsonKey(fromJson: _readQuote)
  final Object? quote;
  final List<MastodonMediaAttachment> mediaAttachments;
  final String? spoilerText;
  final List<Map<String, dynamic>>? emojis;
  final bool? sensitive;
  final List<Map<String, dynamic>>? filtered;
  final Map<String, dynamic>? card;
  final Map<String, dynamic>? poll;
  final int? quotesCount;
  final Map<String, dynamic>? quoteApproval;
  final String? language;
  final String? url;

  /// 投稿が最後に編集された時刻 (#1054)。編集されていなければ null。
  ///
  /// ⚠ **これは「読む側」の情報**で、capsicum が投稿を編集する話ではない
  /// （`docs/CLAUDE.md`「実装しない機能: 投稿の更新」とは別物）。連合先で
  /// 編集された投稿は、自サーバーの設定に関わらず編集済みとして届く。
  final DateTime? editedAt;

  const MastodonStatus({
    required this.id,
    required this.createdAt,
    required this.account,
    required this.content,
    required this.visibility,
    required this.favouritesCount,
    required this.reblogsCount,
    required this.repliesCount,
    this.favourited,
    this.reblogged,
    this.bookmarked,
    this.inReplyToId,
    this.reblog,
    this.quote,
    required this.mediaAttachments,
    this.spoilerText,
    this.emojis,
    this.sensitive,
    this.filtered,
    this.card,
    this.poll,
    this.quotesCount,
    this.quoteApproval,
    this.language,
    this.url,
    this.editedAt,
  });

  factory MastodonStatus.fromJson(Map<String, dynamic> json) =>
      _$MastodonStatusFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonStatusToJson(this);
}

Object? _readQuote(dynamic value) => value;

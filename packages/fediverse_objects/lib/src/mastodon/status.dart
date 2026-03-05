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
  final List<MastodonMediaAttachment> mediaAttachments;
  final String? spoilerText;
  final List<Map<String, dynamic>>? emojis;
  final bool? sensitive;

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
    required this.mediaAttachments,
    this.spoilerText,
    this.emojis,
    this.sensitive,
  });

  factory MastodonStatus.fromJson(Map<String, dynamic> json) =>
      _$MastodonStatusFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonStatusToJson(this);
}

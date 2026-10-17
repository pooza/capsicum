import 'package:json_annotation/json_annotation.dart';

part 'media_attachment.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonMediaAttachment {
  final String id;
  final String type;
  final String? url;
  final String? previewUrl;
  final String? description;

  /// 読み込み中の枠に敷く色の元 (#1186)。無いこともある。
  final String? blurhash;

  const MastodonMediaAttachment({
    required this.id,
    required this.type,
    this.url,
    this.previewUrl,
    this.description,
    this.blurhash,
  });

  factory MastodonMediaAttachment.fromJson(Map<String, dynamic> json) =>
      _$MastodonMediaAttachmentFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonMediaAttachmentToJson(this);
}

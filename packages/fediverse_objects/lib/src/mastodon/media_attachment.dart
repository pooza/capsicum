import 'package:json_annotation/json_annotation.dart';

part 'media_attachment.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonMediaAttachment {
  final String id;
  final String type;
  final String? url;
  final String? previewUrl;
  final String? description;

  const MastodonMediaAttachment({
    required this.id,
    required this.type,
    this.url,
    this.previewUrl,
    this.description,
  });

  factory MastodonMediaAttachment.fromJson(Map<String, dynamic> json) =>
      _$MastodonMediaAttachmentFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonMediaAttachmentToJson(this);
}

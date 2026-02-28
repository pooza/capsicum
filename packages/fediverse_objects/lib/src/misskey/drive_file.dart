import 'package:json_annotation/json_annotation.dart';

part 'drive_file.g.dart';

@JsonSerializable()
class MisskeyDriveFile {
  final String id;
  final String name;
  final String type;
  final String? url;
  final String? thumbnailUrl;
  final String? comment;
  final bool isSensitive;

  const MisskeyDriveFile({
    required this.id,
    required this.name,
    required this.type,
    this.url,
    this.thumbnailUrl,
    this.comment,
    required this.isSensitive,
  });

  factory MisskeyDriveFile.fromJson(Map<String, dynamic> json) =>
      _$MisskeyDriveFileFromJson(json);

  Map<String, dynamic> toJson() => _$MisskeyDriveFileToJson(this);
}

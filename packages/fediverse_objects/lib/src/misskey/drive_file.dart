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

  /// 読み込み中の枠に敷く色の元 (#1186)。無いファイル（音声など）もある。
  final String? blurhash;

  /// `avgColor`（`rgb(r,g,b)`）・`width` / `height` などを持つ。無いこともある。
  final Map<String, dynamic>? properties;

  const MisskeyDriveFile({
    required this.id,
    required this.name,
    required this.type,
    this.url,
    this.thumbnailUrl,
    this.comment,
    required this.isSensitive,
    this.blurhash,
    this.properties,
  });

  factory MisskeyDriveFile.fromJson(Map<String, dynamic> json) =>
      _$MisskeyDriveFileFromJson(json);

  Map<String, dynamic> toJson() => _$MisskeyDriveFileToJson(this);
}

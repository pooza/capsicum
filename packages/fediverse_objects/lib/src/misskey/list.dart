import 'package:json_annotation/json_annotation.dart';

part 'list.g.dart';

@JsonSerializable()
class MisskeyList {
  final String id;
  final String name;

  /// リストを公開しているか。
  final bool? isPublic;

  const MisskeyList({required this.id, required this.name, this.isPublic});

  factory MisskeyList.fromJson(Map<String, dynamic> json) =>
      _$MisskeyListFromJson(json);

  Map<String, dynamic> toJson() => _$MisskeyListToJson(this);
}

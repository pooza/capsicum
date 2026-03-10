import 'package:json_annotation/json_annotation.dart';

part 'list.g.dart';

@JsonSerializable()
class MisskeyList {
  final String id;
  final String name;

  const MisskeyList({required this.id, required this.name});

  factory MisskeyList.fromJson(Map<String, dynamic> json) =>
      _$MisskeyListFromJson(json);

  Map<String, dynamic> toJson() => _$MisskeyListToJson(this);
}

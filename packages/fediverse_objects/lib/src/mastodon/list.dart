import 'package:json_annotation/json_annotation.dart';

part 'list.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonList {
  final String id;
  final String title;

  const MastodonList({required this.id, required this.title});

  factory MastodonList.fromJson(Map<String, dynamic> json) =>
      _$MastodonListFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonListToJson(this);
}

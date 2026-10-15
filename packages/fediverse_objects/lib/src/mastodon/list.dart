import 'package:json_annotation/json_annotation.dart';

part 'list.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonList {
  final String id;
  final String title;

  /// リスト TL に出す返信の範囲（`followed` / `list` / `none`）。
  final String? repliesPolicy;

  /// リストのメンバーの投稿を、ホーム TL から外すか。
  final bool? exclusive;

  const MastodonList({
    required this.id,
    required this.title,
    this.repliesPolicy,
    this.exclusive,
  });

  factory MastodonList.fromJson(Map<String, dynamic> json) =>
      _$MastodonListFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonListToJson(this);
}

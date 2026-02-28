import 'package:json_annotation/json_annotation.dart';

part 'token.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake, createToJson: false)
class MastodonToken {
  final String? accessToken;
  final String? tokenType;
  final String? scope;
  final int? createdAt;

  const MastodonToken({
    this.accessToken,
    this.tokenType,
    this.scope,
    this.createdAt,
  });

  factory MastodonToken.fromJson(Map<String, dynamic> json) =>
      _$MastodonTokenFromJson(json);
}

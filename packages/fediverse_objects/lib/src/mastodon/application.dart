import 'package:json_annotation/json_annotation.dart';

part 'application.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonApplication {
  final String? id;
  final String name;
  final String? clientId;
  final String? clientSecret;
  final String? redirectUri;

  const MastodonApplication({
    this.id,
    required this.name,
    this.clientId,
    this.clientSecret,
    this.redirectUri,
  });

  factory MastodonApplication.fromJson(Map<String, dynamic> json) =>
      _$MastodonApplicationFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonApplicationToJson(this);
}

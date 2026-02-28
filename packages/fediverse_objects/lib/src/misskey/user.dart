import 'package:json_annotation/json_annotation.dart';

part 'user.g.dart';

@JsonSerializable()
class MisskeyUser {
  final String id;
  final String username;
  final String? host;
  final String? name;
  final String? avatarUrl;
  final String? bannerUrl;
  final String? description;
  final int? followersCount;
  final int? followingCount;
  final int? notesCount;

  const MisskeyUser({
    required this.id,
    required this.username,
    this.host,
    this.name,
    this.avatarUrl,
    this.bannerUrl,
    this.description,
    this.followersCount,
    this.followingCount,
    this.notesCount,
  });

  factory MisskeyUser.fromJson(Map<String, dynamic> json) =>
      _$MisskeyUserFromJson(json);

  Map<String, dynamic> toJson() => _$MisskeyUserToJson(this);
}

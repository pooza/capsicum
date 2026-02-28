import 'package:json_annotation/json_annotation.dart';

part 'account.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonAccount {
  final String id;
  final String username;
  final String acct;
  final String displayName;
  final String note;
  final String avatar;
  final String header;
  final int followersCount;
  final int followingCount;
  final int statusesCount;

  const MastodonAccount({
    required this.id,
    required this.username,
    required this.acct,
    required this.displayName,
    required this.note,
    required this.avatar,
    required this.header,
    required this.followersCount,
    required this.followingCount,
    required this.statusesCount,
  });

  factory MastodonAccount.fromJson(Map<String, dynamic> json) =>
      _$MastodonAccountFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonAccountToJson(this);
}

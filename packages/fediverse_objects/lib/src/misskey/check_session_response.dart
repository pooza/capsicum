import 'package:json_annotation/json_annotation.dart';

import 'user.dart';

part 'check_session_response.g.dart';

@JsonSerializable(createToJson: false)
class MisskeyCheckSessionResponse {
  final String token;
  final MisskeyUser user;

  const MisskeyCheckSessionResponse({required this.token, required this.user});

  factory MisskeyCheckSessionResponse.fromJson(Map<String, dynamic> json) =>
      _$MisskeyCheckSessionResponseFromJson(json);
}

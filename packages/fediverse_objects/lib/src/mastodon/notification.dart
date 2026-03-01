import 'package:json_annotation/json_annotation.dart';

import 'account.dart';
import 'status.dart';

part 'notification.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonNotification {
  final String id;
  final String type;
  final DateTime createdAt;
  final MastodonAccount account;
  final MastodonStatus? status;

  const MastodonNotification({
    required this.id,
    required this.type,
    required this.createdAt,
    required this.account,
    this.status,
  });

  factory MastodonNotification.fromJson(Map<String, dynamic> json) =>
      _$MastodonNotificationFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonNotificationToJson(this);
}

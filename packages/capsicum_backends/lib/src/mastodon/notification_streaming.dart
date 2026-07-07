import 'dart:convert';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';

import '../notification_streaming_base.dart';
import 'extensions.dart';

/// Mastodon の `user` stream から notification / announcement event を拾って
/// [Notification] として emit する長寿命接続 (#569)。
///
/// timeline 用の [MastodonStreaming] とは**別接続**にする。timeline streaming は
/// home_screen の lifecycle に縛られるため流用すると通知の発火が画面表示中に
/// 限定されてしまう。reconnect / backoff の共通機構は [NotificationStreamingBase]
/// に集約 (#676)。
class MastodonNotificationStreaming extends NotificationStreamingBase {
  MastodonNotificationStreaming({
    required super.host,
    required super.accessToken,
    super.adminRoleIds,
    super.onParseError,
    super.onStreamError,
    super.onReconnectExhausted,
  });

  @override
  Uri buildStreamUri() => Uri(
    scheme: 'wss',
    host: host,
    path: '/api/v1/streaming',
    queryParameters: {'access_token': accessToken, 'stream': 'user'},
  );

  // `user` stream は URI の `stream=user` で購読が確定するため subscribe 不要。
  @override
  String? buildSubscribeMessage() => null;

  @override
  Notification? parseNotificationMessage(String message) =>
      parseMessage(message, host, adminRoleIds: adminRoleIds);

  /// `user` stream の 1 メッセージを [Notification] に変換する。notification /
  /// announcement 以外の event (update / delete 等) は本経路の対象外で null。
  /// JSON / schema 不正は throw し、`_onMessage` 側で観測層に流す。
  static Notification? parseMessage(
    String message,
    String host, {
    Set<String> adminRoleIds = const {},
  }) {
    final json = jsonDecode(message) as Map<String, dynamic>;
    final event = json['event'];
    final payload = json['payload'];
    if (event == 'notification') {
      final notifJson = payload is String
          ? jsonDecode(payload) as Map<String, dynamic>
          : payload as Map<String, dynamic>;
      return MastodonNotification.fromJson(
        notifJson,
      ).toCapsicum(host, adminRoleIds: adminRoleIds);
    }
    if (event == 'announcement') {
      final annJson = payload is String
          ? jsonDecode(payload) as Map<String, dynamic>
          : payload as Map<String, dynamic>;
      final announcement = MastodonAnnouncement.fromJson(annJson).toCapsicum();
      return Notification(
        // announcement.id は通常の notification.id と名前空間が衝突しうるため
        // prefix で分離 (dispatcher の dedup set 取り違え防止)。
        id: 'announcement:${announcement.id}',
        type: NotificationType.announcement,
        createdAt: announcement.publishedAt,
        announcement: announcement,
      );
    }
    return null;
  }
}

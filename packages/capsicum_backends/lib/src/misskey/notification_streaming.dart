import 'dart:convert';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:uuid/uuid.dart';

import '../notification_streaming_base.dart';
import 'extensions.dart';

/// Misskey の `main` channel から notification / announcementCreated event を
/// 拾って [Notification] として emit する長寿命接続 (#569)。
///
/// timeline 用の [MisskeyStreaming] とは**別接続**にする (理由は Mastodon 側と
/// 同じ)。reconnect / backoff の共通機構は [NotificationStreamingBase] に集約
/// (#676)。
class MisskeyNotificationStreaming extends NotificationStreamingBase {
  MisskeyNotificationStreaming({
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
    path: '/streaming',
    queryParameters: {'i': accessToken},
  );

  // `main` channel に subscribe して個人宛 event (notification 等) を受ける。
  // subscriptionId は接続ごとに使い捨て（unsubscribe しないため保持不要）。
  @override
  String? buildSubscribeMessage() => jsonEncode({
    'type': 'connect',
    'body': {'channel': 'main', 'id': const Uuid().v4()},
  });

  @override
  Notification? parseNotificationMessage(String message) =>
      parseMessage(message, host, adminRoleIds: adminRoleIds);

  /// `main` channel の 1 メッセージを [Notification] に変換する。notification /
  /// announcementCreated 以外 (channel 外 message や他 event) は対象外で null。
  /// JSON / schema 不正は throw し、`_onMessage` 側で観測層に流す。
  static Notification? parseMessage(
    String message,
    String host, {
    Set<String> adminRoleIds = const {},
  }) {
    final json = jsonDecode(message) as Map<String, dynamic>;
    if (json['type'] != 'channel') return null;
    final body = json['body'] as Map<String, dynamic>;
    final eventType = body['type'];
    if (eventType == 'notification') {
      final notifJson = body['body'] as Map<String, dynamic>;
      return MisskeyNotification.fromJson(
        notifJson,
      ).toCapsicum(host, adminRoleIds: adminRoleIds);
    }
    if (eventType == 'announcementCreated') {
      // main channel の announcementCreated は body.body.announcement に
      // お知らせ本体を入れて配る。
      final inner = body['body'] as Map<String, dynamic>;
      final annJson = inner['announcement'] as Map<String, dynamic>;
      final announcement = MisskeyAnnouncement.fromJson(annJson).toCapsicum();
      return Notification(
        id: 'announcement:${announcement.id}',
        type: NotificationType.announcement,
        createdAt: announcement.publishedAt,
        announcement: announcement,
      );
    }
    return null;
  }
}

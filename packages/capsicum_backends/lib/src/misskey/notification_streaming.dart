import 'dart:async';
import 'dart:convert';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'extensions.dart';

/// Misskey の `main` channel から notification / announcementCreated event を
/// 拾って [Notification] として emit する長寿命接続 (#569)。
///
/// timeline 用の [MisskeyStreaming] とは**別接続**にする (理由は Mastodon 側と
/// 同じ)。reconnect / backoff は [MisskeyStreaming] と同じ機構。
class MisskeyNotificationStreaming {
  final String host;
  final String accessToken;
  final Set<String> adminRoleIds;

  final void Function(Object error, StackTrace stack)? onParseError;
  final void Function(Object error, StackTrace stack)? onStreamError;
  final void Function()? onReconnectExhausted;

  WebSocketChannel? _channel;
  StreamController<Notification>? _controller;
  Timer? _reconnectTimer;
  String? _subscriptionId;
  bool _disposed = false;
  bool _reconnectExhaustedNotified = false;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 10;
  static const _baseReconnectDelay = Duration(seconds: 5);
  static const _maxReconnectDelay = Duration(seconds: 300);
  // 無音切断を検知するための WS ping/pong。pong が無ければ自動 close → onDone →
  // 再接続が走る (#788)。通知は緊急性が低めなので timeline より長め。
  static const _pingInterval = Duration(seconds: 60);

  MisskeyNotificationStreaming({
    required this.host,
    required this.accessToken,
    this.adminRoleIds = const {},
    this.onParseError,
    this.onStreamError,
    this.onReconnectExhausted,
  });

  Stream<Notification> connect() {
    _controller?.close();
    _controller = StreamController<Notification>.broadcast(onCancel: dispose);
    _connect();
    return _controller!.stream;
  }

  void _connect() {
    if (_disposed) return;
    _channel?.sink.close();

    final uri = Uri(
      scheme: 'wss',
      host: host,
      path: '/streaming',
      queryParameters: {'i': accessToken},
    );

    _channel = IOWebSocketChannel.connect(uri, pingInterval: _pingInterval);
    _channel!.stream.listen(
      _onMessage,
      onError: (Object error, StackTrace stack) {
        _notifyStreamError(error, stack);
        _scheduleReconnect();
      },
      // onDone でバックオフをリセットしない。接続直後に即 close する不調な
      // サーバーに対し、リセットすると 5s 間隔のタイト再接続ループに陥り
      // exponential backoff も exhausted 通知も効かなくなる (Mastodon
      // NotificationStreaming と同型。リセットは接続成功時の ready.then のみ)。
      onDone: _scheduleReconnect,
    );

    // `main` channel に subscribe して個人宛 event (notification 等) を受ける。
    _subscriptionId = const Uuid().v4();
    final channel = _channel!;
    final subId = _subscriptionId!;
    channel.ready
        .then((_) {
          _reconnectAttempts = 0;
          _reconnectExhaustedNotified = false;
          if (_disposed || _channel != channel) return;
          channel.sink.add(
            jsonEncode({
              'type': 'connect',
              'body': {'channel': 'main', 'id': subId},
            }),
          );
        })
        .catchError((Object error, StackTrace stack) {
          _notifyStreamError(error, stack);
          _scheduleReconnect();
        });
  }

  void _notifyStreamError(Object error, StackTrace stack) {
    try {
      onStreamError?.call(error, stack);
    } catch (_) {
      // 観測経路の失敗で本筋を止めない。
    }
  }

  void _onMessage(dynamic message) {
    if (message is! String) return;
    try {
      final notification = parseMessage(
        message,
        host,
        adminRoleIds: adminRoleIds,
      );
      if (notification != null) _controller?.add(notification);
    } catch (e, st) {
      // raw payload を捨てる前に観測層へ流す (MisskeyStreaming と同型、#586)。
      try {
        onParseError?.call(e, st);
      } catch (_) {
        // 観測経路の失敗で本筋を止めない。
      }
    }
  }

  /// `main` channel の 1 メッセージを [Notification] に変換する。notification /
  /// announcementCreated 以外 (channel 外 message や他 event) は対象外で null。
  /// JSON / schema 不正は throw し、[_onMessage] 側で観測層に流す。
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

  void _scheduleReconnect() {
    if (_disposed) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      if (!_reconnectExhaustedNotified) {
        _reconnectExhaustedNotified = true;
        try {
          onReconnectExhausted?.call();
        } catch (_) {
          // 観測経路の失敗で本筋を止めない。
        }
      }
      return;
    }
    _reconnectTimer?.cancel();
    final delaySecs = _baseReconnectDelay.inSeconds * (1 << _reconnectAttempts);
    final delay = Duration(
      seconds: delaySecs.clamp(0, _maxReconnectDelay.inSeconds),
    );
    _reconnectAttempts++;
    _reconnectTimer = Timer(delay, () {
      if (!_disposed) _connect();
    });
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _controller?.close();
    _controller = null;
  }
}

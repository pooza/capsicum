import 'dart:async';
import 'dart:convert';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'extensions.dart';

/// Mastodon の `user` stream から notification / announcement event を拾って
/// [Notification] として emit する長寿命接続 (#569)。
///
/// timeline 用の [MastodonStreaming] とは**別接続**にする。timeline streaming は
/// home_screen の lifecycle に縛られるため流用すると通知の発火が画面表示中に
/// 限定されてしまう。reconnect / backoff は [MastodonStreaming] と同じ機構。
class MastodonNotificationStreaming {
  final String host;
  final String accessToken;
  final Set<String> adminRoleIds;

  final void Function(Object error, StackTrace stack)? onParseError;
  final void Function(Object error, StackTrace stack)? onStreamError;
  final void Function()? onReconnectExhausted;

  WebSocketChannel? _channel;
  StreamController<Notification>? _controller;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _reconnectExhaustedNotified = false;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 10;
  static const _baseReconnectDelay = Duration(seconds: 5);
  static const _maxReconnectDelay = Duration(seconds: 300);
  // 無音切断を検知するための WS ping/pong。pong が無ければ自動 close → onDone →
  // 再接続が走る (#788)。通知は緊急性が低めなので timeline より長め。
  static const _pingInterval = Duration(seconds: 60);

  MastodonNotificationStreaming({
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
      path: '/api/v1/streaming',
      queryParameters: {'access_token': accessToken, 'stream': 'user'},
    );

    _channel = IOWebSocketChannel.connect(uri, pingInterval: _pingInterval);
    _channel!.ready
        .then((_) {
          _reconnectAttempts = 0;
          _reconnectExhaustedNotified = false;
        })
        .catchError((Object error, StackTrace stack) {
          _notifyStreamError(error, stack);
          _scheduleReconnect();
        });
    _channel!.stream.listen(
      _onMessage,
      onError: (Object error, StackTrace stack) {
        _notifyStreamError(error, stack);
        _scheduleReconnect();
      },
      // onDone でバックオフをリセットしない理由は MastodonStreaming と同じ
      // (接続成功時のみ ready.then でリセット)。
      onDone: _scheduleReconnect,
    );
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
      // raw payload を捨てる前に観測層へ流す (MastodonStreaming と同型、#586)。
      try {
        onParseError?.call(e, st);
      } catch (_) {
        // 観測経路の失敗で本筋を止めない。
      }
    }
  }

  /// `user` stream の 1 メッセージを [Notification] に変換する。notification /
  /// announcement 以外の event (update / delete 等) は本経路の対象外で null。
  /// JSON / schema 不正は throw し、[_onMessage] 側で観測層に流す。
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

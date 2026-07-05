import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// notification / announcement を配信する長寿命 WebSocket 接続の共通基盤 (#676)。
///
/// Mastodon の `user` stream 用 [MastodonNotificationStreaming] と Misskey の
/// `main` channel 用 [MisskeyNotificationStreaming] で、再接続機構・定数・観測
/// コールバック・WebSocket セットアップが byte-for-byte 同一だったため集約した
/// （[MisskeyChatStreamingBase]（#627）と同じ手当て）。platform 固有なのは接続
/// URI・subscribe メッセージ・メッセージのパースの 3 点だけで、それぞれ
/// [buildStreamUri] / [buildSubscribeMessage] / [parseNotificationMessage] の
/// 抽象メソッドに切り出す。
abstract class NotificationStreamingBase {
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

  NotificationStreamingBase({
    required this.host,
    required this.accessToken,
    this.adminRoleIds = const {},
    this.onParseError,
    this.onStreamError,
    this.onReconnectExhausted,
  });

  /// 接続先の WebSocket URI（platform 固有）。
  Uri buildStreamUri();

  /// 接続確立 (ready) 後に送る subscribe メッセージ（JSON 文字列）。subscribe が
  /// 不要なら null を返す（Mastodon の `user` stream は URI の `stream=user` で
  /// 購読が確定するため不要。Misskey は `main` channel への connect が要る）。
  String? buildSubscribeMessage();

  /// 1 メッセージを [Notification] へ変換する（platform 固有パース）。notification
  /// / announcement 以外は null。JSON / schema 不正は throw し、[_onMessage] 側で
  /// 観測層 ([onParseError]) に流す。
  Notification? parseNotificationMessage(String message);

  Stream<Notification> connect() {
    _controller?.close();
    _controller = StreamController<Notification>.broadcast(onCancel: dispose);
    _connect();
    return _controller!.stream;
  }

  void _connect() {
    if (_disposed) return;
    _channel?.sink.close();

    final channel = IOWebSocketChannel.connect(
      buildStreamUri(),
      pingInterval: _pingInterval,
    );
    _channel = channel;
    // listener / catchError は前世代 channel の close でも発火しうるので、
    // クロージャ捕捉した channel が現役かで判定し、旧世代の onDone / onError で
    // 余計な reconnect Timer が積まれるのを防ぐ (#548)。
    channel.stream.listen(
      _onMessage,
      onError: (Object error, StackTrace stack) {
        if (_channel != channel) return;
        _notifyStreamError(error, stack);
        _scheduleReconnect();
      },
      // onDone でバックオフをリセットしない。接続直後に即 close する不調な
      // サーバーに対しリセットすると 5s 間隔のタイト再接続ループに陥り、
      // exponential backoff も exhausted 通知も効かなくなる（リセットは接続
      // 成功時の ready.then のみ）。
      onDone: () {
        if (_channel == channel) _scheduleReconnect();
      },
    );

    channel.ready
        .then((_) {
          if (_disposed || _channel != channel) return;
          _reconnectAttempts = 0;
          _reconnectExhaustedNotified = false;
          final subscribe = buildSubscribeMessage();
          if (subscribe != null) channel.sink.add(subscribe);
        })
        .catchError((Object error, StackTrace stack) {
          if (_channel != channel) return;
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
      final notification = parseNotificationMessage(message);
      if (notification != null) _controller?.add(notification);
    } catch (e, st) {
      // raw payload を捨てる前に観測層へ流す (#586)。サーバー側 schema 変更や
      // fediverse_objects のパース失敗を「ストリーミング来ない」だけで気付け
      // なくなるのを避ける。
      try {
        onParseError?.call(e, st);
      } catch (_) {
        // 観測経路の失敗で本筋を止めない。
      }
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      // 諦めたまま _controller を開きっぱなしにすると UI は「接続中」のまま無期限に
      // 待つ。callback で外に出して呼び出し側に判断させる (#552)。一度きり通知。
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

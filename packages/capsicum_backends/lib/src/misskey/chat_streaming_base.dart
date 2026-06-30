import 'dart:async';
import 'dart:convert';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Misskey の `/streaming` WebSocket を 1 本張り、指数バックオフ再接続つきで
/// [ChatMessage] を配信する共通基盤 (#627)。
///
/// DM 用 [MisskeyChatStreaming]（`main` channel）とルーム用
/// [MisskeyChatRoomStreaming]（`chatRoom` channel）で、再接続機構・定数・
/// 観測コールバック・WebSocket セットアップが完全に重複していたため集約した。
/// channel 固有の差分だけを [buildConnectBody] / [parseChannelMessage] の
/// 2 つの抽象メソッドに切り出す。
abstract class MisskeyChatStreamingBase {
  final String host;
  final String accessToken;
  final Set<String> adminRoleIds;
  final User? selfUser;
  final void Function(Object error, StackTrace stack)? onParseError;
  final void Function(Object error, StackTrace stack)? onStreamError;
  final void Function()? onReconnectExhausted;

  WebSocketChannel? _channel;
  StreamController<ChatMessage>? _controller;
  Timer? _reconnectTimer;
  String? _subscriptionId;
  bool _disposed = false;
  bool _reconnectExhaustedNotified = false;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 10;
  static const _baseReconnectDelay = Duration(seconds: 5);
  static const _maxReconnectDelay = Duration(seconds: 300);
  // 無音切断を検知するための WS ping/pong。pong が無ければ自動 close → onDone →
  // 再接続が走る (#788)。チャットは緊急性が低めなので timeline より長め。
  static const _pingInterval = Duration(seconds: 60);

  MisskeyChatStreamingBase({
    required this.host,
    required this.accessToken,
    this.adminRoleIds = const {},
    this.selfUser,
    this.onParseError,
    this.onStreamError,
    this.onReconnectExhausted,
  });

  /// 購読する channel の connect メッセージ body
  /// （`{'type': 'connect', 'body': <ここ>}` の `body`）を組み立てる。
  Map<String, dynamic> buildConnectBody(String subscriptionId);

  /// channel イベントの `body`（`{'type': ..., 'body': ...}`）から emit すべき
  /// [ChatMessage] を取り出す。対象外のイベントは `null` を返す。例外は
  /// 呼び出し側の [_onMessage] が捕捉し [onParseError] に流す。
  ChatMessage? parseChannelMessage(Map<String, dynamic> body);

  Stream<ChatMessage> connect() {
    _controller?.close();
    _controller = StreamController<ChatMessage>.broadcast(onCancel: dispose);
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

    final channel = IOWebSocketChannel.connect(uri, pingInterval: _pingInterval);
    _channel = channel;
    // listener / catchError は前世代 channel の close でも発火しうるので
    // 「現役 channel と同一か」をクロージャ捕捉した channel で判定し、旧世代の
    // onDone / onError で余計な reconnect Timer が積まれるのを防ぐ (#548)。
    // error は #552 で onStreamError 経路に流す。
    channel.stream.listen(
      _onMessage,
      onError: (Object error, StackTrace stack) {
        if (_channel != channel) return;
        _notifyStreamError(error, stack);
        _scheduleReconnect();
      },
      onDone: () {
        if (_channel == channel) _scheduleReconnect();
      },
    );

    _subscriptionId = const Uuid().v4();
    final subId = _subscriptionId!;
    channel.ready
        .then((_) {
          if (_disposed || _channel != channel) return;
          _reconnectAttempts = 0;
          _reconnectExhaustedNotified = false;
          channel.sink.add(
            jsonEncode({'type': 'connect', 'body': buildConnectBody(subId)}),
          );
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
      final json = jsonDecode(message) as Map<String, dynamic>;
      if (json['type'] != 'channel') return;
      final body = json['body'] as Map<String, dynamic>;
      final chatMessage = parseChannelMessage(body);
      if (chatMessage != null) _controller?.add(chatMessage);
    } catch (e, st) {
      // raw payload を捨てる前に観測層へ流す。サーバー側 schema 変更や
      // fediverse_objects のパース失敗を「ストリーミング来ない」だけで
      // 気付けなくなるのを避ける (#448)。呼び出し側で Sentry breadcrumb /
      // captureException に繋ぐ (chat_provider 側でレート制限付き)。
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
      // 諦めたまま _controller を開きっぱなしにすると、UI 側は「接続中」のまま
      // 無期限に新規イベントを待つことになる。callback で外に出して呼び出し側に
      // 判断させる (#552)。一度きり通知する。
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

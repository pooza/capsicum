import 'dart:async';
import 'dart:convert';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'extensions.dart';

/// Misskey の `main` channel を購読し、`newChatMessage` イベントを
/// `ChatMessage` ストリームとして配信する。
///
/// `main` channel は notification / mention / newChatMessage 等多数のイベントを
/// 流すが、本クラスは chat 用に `newChatMessage` のみフィルタして emit する。
/// より granular なスレッド単位イベント (read / deleted / reaction) が必要なら
/// 別途 `chatUser` channel (otherId 必須) を購読する。
class MisskeyChatStreaming {
  final String host;
  final String accessToken;
  final Set<String> adminRoleIds;
  final User? selfUser;

  WebSocketChannel? _channel;
  StreamController<ChatMessage>? _controller;
  Timer? _reconnectTimer;
  String? _subscriptionId;
  bool _disposed = false;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 10;
  static const _baseReconnectDelay = Duration(seconds: 5);
  static const _maxReconnectDelay = Duration(seconds: 300);

  MisskeyChatStreaming({
    required this.host,
    required this.accessToken,
    this.adminRoleIds = const {},
    this.selfUser,
  });

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

    _channel = WebSocketChannel.connect(uri);
    _channel!.stream.listen(
      _onMessage,
      onError: (_) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
    );

    _subscriptionId = const Uuid().v4();
    final channel = _channel!;
    final subId = _subscriptionId!;
    channel.ready
        .then((_) {
          _reconnectAttempts = 0;
          if (_disposed || _channel != channel) return;
          channel.sink.add(
            jsonEncode({
              'type': 'connect',
              'body': {'channel': 'main', 'id': subId},
            }),
          );
        })
        .catchError((_) {
          _scheduleReconnect();
        });
  }

  void _onMessage(dynamic message) {
    if (message is! String) return;
    try {
      final json = jsonDecode(message) as Map<String, dynamic>;
      if (json['type'] != 'channel') return;
      final body = json['body'] as Map<String, dynamic>;
      if (body['type'] != 'newChatMessage') return;
      final messageBody = body['body'];
      if (messageBody is! Map<String, dynamic>) return;
      final chatMessage = misskeyChatMessageFromMap(
        messageBody,
        host,
        adminRoleIds: adminRoleIds,
        selfUser: selfUser,
      );
      _controller?.add(chatMessage);
    } catch (_) {
      // Ignore malformed messages.
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) return;
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

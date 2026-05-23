import 'dart:async';
import 'dart:convert';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'extensions.dart';

/// Misskey の `chatRoom` channel (`{roomId}` param) を購読し、ルーム宛
/// `message` イベントを [ChatMessage] ストリームとして配信する (#438)。
///
/// 1 インスタンス = 1 ルーム。DM 用の [MisskeyChatStreaming] が `main` channel
/// を 1 本だけ張って全 DM を受けるのに対し、ルームはサーバー側仕様 (Misskey の
/// stream/channels/chat-room.ts は `roomId` を init で 1 つだけ受け取る) により
/// 「自分の参加全ルームを 1 本でまとめて受ける aggregate channel」が存在しない。
/// 表示中のルームに対して都度購読 / 切断する運用を前提とする。
class MisskeyChatRoomStreaming {
  final String host;
  final String accessToken;
  final String roomId;
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

  MisskeyChatRoomStreaming({
    required this.host,
    required this.accessToken,
    required this.roomId,
    this.adminRoleIds = const {},
    this.selfUser,
    this.onParseError,
    this.onStreamError,
    this.onReconnectExhausted,
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

    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    // 旧世代 channel の close / error が新世代 reconnect に被らないよう
    // クロージャ捕捉した channel と現役 channel の同一性で判定する
    // (DM 側 MisskeyChatStreaming #548 と同方針)。
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
            jsonEncode({
              'type': 'connect',
              'body': {
                'channel': 'chatRoom',
                'id': subId,
                'params': {'roomId': roomId},
              },
            }),
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
      // chatRoom channel が emit するイベント。Misskey は ChatRoomChannel
      // から「サーバー側 chatRoomStream:<roomId> の全 event type」をそのまま
      // 流すため、新着メッセージは `message` イベントとして来る (read 等の
      // 他イベントは今回スコープ外)。
      if (body['type'] != 'message') return;
      final messageBody = body['body'];
      if (messageBody is! Map<String, dynamic>) return;
      // ルーム宛は ChatMessageLiteForRoom 形 (toRoomId のみで toUserId なし)。
      // パーサーは toRoom が無くても toRoomId だけで room メッセージと識別する。
      final chatMessage = misskeyChatMessageFromMap(
        messageBody,
        host,
        adminRoleIds: adminRoleIds,
        selfUser: selfUser,
        defaultIsRead: true,
      );
      _controller?.add(chatMessage);
    } catch (e, st) {
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

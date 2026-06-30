import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../streaming_backoff.dart';
import 'extensions.dart';

const _channelMap = <TimelineType, String>{
  TimelineType.home: 'homeTimeline',
  TimelineType.local: 'localTimeline',
  TimelineType.social: 'hybridTimeline',
  TimelineType.federated: 'globalTimeline',
};

class MisskeyStreaming {
  final String host;
  final String accessToken;
  final Set<String> adminRoleIds;

  /// 本線タイムライン streaming の観測コールバック (#586)。chat_streaming
  /// (#448 / #552) と同型。null なら無視。原因対処はせず計器のみ生やす。
  final void Function(Object error, StackTrace stack)? onParseError;
  final void Function(Object error, StackTrace stack)? onStreamError;
  final void Function()? onReconnectExhausted;

  /// 接続ライフサイクルの遷移を呼び出し側 (UI インジケータ) へ流す (#714)。
  final void Function(StreamConnectionState state)? onConnectionState;

  WebSocketChannel? _channel;
  StreamController<Post>? _controller;
  Timer? _reconnectTimer;
  TimelineType? _currentType;
  String? _subscriptionId;
  bool _disposed = false;
  bool _reconnectExhaustedNotified = false;
  StreamConnectionState? _lastConnectionState;
  int _reconnectAttempts = 0;
  final Random _random = Random();
  // 上限 = exhausted を一度だけ通知する閾値（give-up はしない, #784）。
  static const _maxReconnectAttempts = 10;
  // 初動は速く（瞬間 503 / 瞬断から数秒で復帰）、上限は live クライアント向けに
  // 短め。jitter は streaming_backoff 側で付与 (#784)。
  static const _baseReconnectDelay = Duration(seconds: 1);
  static const _maxReconnectDelay = Duration(seconds: 60);
  // 無音切断を検知するための WS ping/pong。pong が無ければ自動 close → onDone →
  // 再接続が走る (#788)。本線タイムラインは即時性が要るので短め。
  static const _pingInterval = Duration(seconds: 30);

  MisskeyStreaming({
    required this.host,
    required this.accessToken,
    this.adminRoleIds = const {},
    this.onParseError,
    this.onStreamError,
    this.onReconnectExhausted,
    this.onConnectionState,
  });

  // 同じ状態が連続するときは UI へ重複通知しない (#714)。観測経路の失敗で
  // 本筋を止めない。
  void _notifyConnectionState(StreamConnectionState next) {
    if (_disposed || _lastConnectionState == next) return;
    _lastConnectionState = next;
    try {
      onConnectionState?.call(next);
    } catch (_) {}
  }

  Stream<Post> connect(TimelineType type) {
    _currentType = type;
    _controller?.close();
    _controller = StreamController<Post>.broadcast(onCancel: dispose);
    _connect(type);
    return _controller!.stream;
  }

  void _connect(TimelineType type) {
    if (_disposed) return;
    _channel?.sink.close();
    _notifyConnectionState(StreamConnectionState.connecting);

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
        _notifyConnectionState(StreamConnectionState.disconnected);
        _scheduleReconnect();
      },
      onDone: () {
        // onDone でバックオフをリセットすると「接続→onDone→reset→再接続→
        // onDone→reset」のループでバックオフが基底値のまま動かず、上限到達に
        // よる `onReconnectExhausted` 通知も出なくなる。リセットは接続成功
        // (`ready.then`) 時のみに揃える（Mastodon 側 streaming.dart と同挙動）。
        _notifyConnectionState(StreamConnectionState.disconnected);
        _scheduleReconnect();
      },
    );

    // Subscribe to the timeline channel after connecting.
    _subscriptionId = const Uuid().v4();
    final channelName = _channelMap[type] ?? 'homeTimeline';
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
              'body': {'channel': channelName, 'id': subId},
            }),
          );
          _notifyConnectionState(StreamConnectionState.live);
        })
        .catchError((Object error, StackTrace stack) {
          _notifyStreamError(error, stack);
          _notifyConnectionState(StreamConnectionState.disconnected);
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
      if (body['type'] != 'note') return;
      final noteJson = body['body'] as Map<String, dynamic>;
      final note = MisskeyNote.fromJson(noteJson);
      _controller?.add(note.toCapsicum(host, adminRoleIds: adminRoleIds));
    } catch (e, st) {
      // raw payload を捨てる前に観測層へ流す。サーバー側 schema 変更や
      // パース失敗を「ストリーミング来ない」だけで気付けなくなるのを避ける
      // (#586 / chat_streaming #448 と同型)。
      try {
        onParseError?.call(e, st);
      } catch (_) {
        // 観測経路の失敗で本筋を止めない。
      }
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    // 上限到達時、exhausted を一度だけ通知して呼び出し側 (UI / 観測) に知らせる
    // (#586 / #552)。ただし **give-up はせず** 低頻度で再試行を続ける (#784)：
    // 間欠的に失敗するサーバー / 瞬断回線でも live 復帰の機会を捨てない。復帰
    // すれば since_id catch-up (#781) が穴を埋める。
    if (_reconnectAttempts >= _maxReconnectAttempts &&
        !_reconnectExhaustedNotified) {
      _reconnectExhaustedNotified = true;
      try {
        onReconnectExhausted?.call();
      } catch (_) {
        // 観測経路の失敗で本筋を止めない。
      }
      _notifyConnectionState(StreamConnectionState.exhausted);
    }
    _reconnectTimer?.cancel();
    final delayMs = reconnectBackoffMs(
      _reconnectAttempts,
      baseMs: _baseReconnectDelay.inMilliseconds,
      maxMs: _maxReconnectDelay.inMilliseconds,
      random: _random,
    );
    _reconnectAttempts++;
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_disposed && _currentType != null) {
        _connect(_currentType!);
      }
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

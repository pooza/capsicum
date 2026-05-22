import 'dart:async';
import 'dart:convert';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

  WebSocketChannel? _channel;
  StreamController<Post>? _controller;
  Timer? _reconnectTimer;
  TimelineType? _currentType;
  String? _subscriptionId;
  bool _disposed = false;
  bool _reconnectExhaustedNotified = false;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 10;
  static const _baseReconnectDelay = Duration(seconds: 5);
  static const _maxReconnectDelay = Duration(seconds: 300);

  MisskeyStreaming({
    required this.host,
    required this.accessToken,
    this.adminRoleIds = const {},
    this.onParseError,
    this.onStreamError,
    this.onReconnectExhausted,
  });

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

    final uri = Uri(
      scheme: 'wss',
      host: host,
      path: '/streaming',
      queryParameters: {'i': accessToken},
    );

    _channel = WebSocketChannel.connect(uri);
    _channel!.stream.listen(
      _onMessage,
      onError: (Object error, StackTrace stack) {
        _notifyStreamError(error, stack);
        _scheduleReconnect();
      },
      onDone: () {
        _reconnectAttempts = 0;
        _reconnectExhaustedNotified = false;
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
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      // 諦めたまま _controller を開きっぱなしにすると UI 側は「接続中」の
      // まま無期限に新規イベントを待つ。callback で外に出して呼び出し側に
      // 判断させる (#586 / #552 と同型)。一度きり通知する。
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

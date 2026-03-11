import 'dart:async';
import 'dart:convert';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'extensions.dart';

const _streamMap = <TimelineType, String>{
  TimelineType.home: 'user',
  TimelineType.local: 'public:local',
  TimelineType.federated: 'public',
};

class MastodonStreaming {
  final String host;
  final String accessToken;

  WebSocketChannel? _channel;
  StreamController<Post>? _controller;
  Timer? _reconnectTimer;
  TimelineType? _currentType;
  bool _disposed = false;

  MastodonStreaming({required this.host, required this.accessToken});

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

    final stream = _streamMap[type] ?? 'user';
    final uri = Uri(
      scheme: 'wss',
      host: host,
      path: '/api/v1/streaming',
      queryParameters: {'access_token': accessToken, 'stream': stream},
    );

    _channel = WebSocketChannel.connect(uri);
    _channel!.ready.catchError((_) => _scheduleReconnect());
    _channel!.stream.listen(
      _onMessage,
      onError: (_) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
    );
  }

  void _onMessage(dynamic message) {
    if (message is! String) return;
    try {
      final json = jsonDecode(message) as Map<String, dynamic>;
      if (json['event'] != 'update') return;
      final payload = json['payload'];
      final statusJson = payload is String
          ? jsonDecode(payload) as Map<String, dynamic>
          : payload as Map<String, dynamic>;
      final status = MastodonStatus.fromJson(statusJson);
      _controller?.add(status.toCapsicum(host));
    } catch (_) {
      // Ignore malformed messages.
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
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

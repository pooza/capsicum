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

  WebSocketChannel? _channel;
  StreamController<Post>? _controller;
  Timer? _reconnectTimer;
  TimelineType? _currentType;
  String? _subscriptionId;
  bool _disposed = false;

  MisskeyStreaming({required this.host, required this.accessToken});

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
      onError: (_) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
    );

    // Subscribe to the timeline channel after connecting.
    _subscriptionId = const Uuid().v4();
    final channelName = _channelMap[type] ?? 'homeTimeline';
    _channel!.ready
        .then((_) {
          if (_disposed) return;
          _channel!.sink.add(
            jsonEncode({
              'type': 'connect',
              'body': {'channel': channelName, 'id': _subscriptionId},
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
      if (body['type'] != 'note') return;
      final noteJson = body['body'] as Map<String, dynamic>;
      final note = MisskeyNote.fromJson(noteJson);
      _controller?.add(note.toCapsicum(host));
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

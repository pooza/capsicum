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

  /// role ID ベースの管理者判定に使う。REST 経路 (`MastodonAdapter._adminRoleIds`)
  /// と同じ値を渡し、streaming 経由でライブ追加された投稿でも同一管理者が
  /// 一貫してマーキングされるようにする (#600)。
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
  bool _disposed = false;
  bool _reconnectExhaustedNotified = false;
  StreamConnectionState? _lastConnectionState;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 10;
  static const _baseReconnectDelay = Duration(seconds: 5);
  static const _maxReconnectDelay = Duration(seconds: 300);

  MastodonStreaming({
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

    final stream = _streamMap[type] ?? 'user';
    final uri = Uri(
      scheme: 'wss',
      host: host,
      path: '/api/v1/streaming',
      queryParameters: {'access_token': accessToken, 'stream': stream},
    );

    _channel = WebSocketChannel.connect(uri);
    _channel!.ready
        .then((_) {
          _reconnectAttempts = 0;
          _reconnectExhaustedNotified = false;
          _notifyConnectionState(StreamConnectionState.live);
        })
        .catchError((Object error, StackTrace stack) {
          _notifyStreamError(error, stack);
          _notifyConnectionState(StreamConnectionState.disconnected);
          _scheduleReconnect();
        });
    _channel!.stream.listen(
      _onMessage,
      onError: (Object error, StackTrace stack) {
        _notifyStreamError(error, stack);
        _notifyConnectionState(StreamConnectionState.disconnected);
        _scheduleReconnect();
      },
      onDone: () {
        // onDone でバックオフをリセットしてしまうと「接続→onDone→reset→
        // 再接続→onDone→reset」のループでバックオフが基底値のまま動かず、
        // 上限到達による `onReconnectExhausted` 通知も出なくなる。リセット
        // は `ready.then` の接続成功時のみ行い、DM (`chat_streaming.dart`) /
        // ルーム (`chat_room_streaming.dart`) と挙動を揃える。
        _notifyConnectionState(StreamConnectionState.disconnected);
        _scheduleReconnect();
      },
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
      final json = jsonDecode(message) as Map<String, dynamic>;
      if (json['event'] != 'update') return;
      final payload = json['payload'];
      final statusJson = payload is String
          ? jsonDecode(payload) as Map<String, dynamic>
          : payload as Map<String, dynamic>;
      final status = MastodonStatus.fromJson(statusJson);
      _controller?.add(status.toCapsicum(host, adminRoleIds: adminRoleIds));
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
      _notifyConnectionState(StreamConnectionState.exhausted);
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

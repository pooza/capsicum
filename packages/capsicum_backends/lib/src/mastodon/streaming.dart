import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../streaming_backoff.dart';
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
  final Random _random = Random();
  // 上限 = exhausted を一度だけ通知する閾値（give-up はしない, #784）。
  static const _maxReconnectAttempts = 10;
  // 初動は速く（瞬間 503 / 瞬断から数秒で復帰）、上限は live クライアント向けに
  // 短め（5 分待ちは実況で長すぎる）。jitter は streaming_backoff 側で付与 (#784)。
  static const _baseReconnectDelay = Duration(seconds: 1);
  static const _maxReconnectDelay = Duration(seconds: 60);
  // 無音切断（NAT/プロキシのアイドル切断・ungraceful な離脱）では FIN/RST が
  // 来ず onDone/onError が発火しないため、ping/pong を張らないと「繋がっている
  // つもり」で死んだソケットに座り続け再接続が走らない (#788)。pingInterval を
  // 設定すると dart:io が ping を送り、同間隔内に pong が無ければ自動で close →
  // onDone 発火 → 既存の再接続ロジックが動く。検知時間 ≒ pingInterval。本線
  // タイムラインは即時性が要るので短め。
  static const _pingInterval = Duration(seconds: 30);

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

    _channel = IOWebSocketChannel.connect(uri, pingInterval: _pingInterval);
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
    // 上限到達時、exhausted を一度だけ通知して呼び出し側 (UI / 観測) に知らせる
    // (#586 / #552)。ただし **give-up はせず** 低頻度で再試行を続ける (#784)：
    // 間欠的に失敗するサーバー (例: 高負荷時に一瞬 503 を返す箱) / 瞬断回線でも
    // live 復帰の機会を捨てない。復帰すれば since_id catch-up (#781) が穴を埋める。
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

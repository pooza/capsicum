import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../reconnecting_socket.dart';
import '../streaming_backoff.dart';

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

  /// WebSocket を開く手段。null なら実際に接続する。テストの差し替え口
  /// （通知側の `NotificationStreamingBase.channelFactory` と同じ形）。
  final WebSocketChannel Function(Uri uri)? channelFactory;

  /// 接続の節目（`connected` / `subscribed` / `disconnected`）を知らせる (#1252)。
  final void Function(String event)? onConnectionEvent;

  StreamController<ChatMessage>? _controller;
  ReconnectingSocket? _socket;
  final Random _random = Random();
  static const _baseReconnectDelay = Duration(seconds: 5);
  // ⚠ 通知側と同じ 60 秒 (#1252)。以前は 300 秒で、しかも 10 回で諦めていた。
  static const _maxReconnectDelay = Duration(seconds: 60);
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
    this.onConnectionEvent,
    this.channelFactory,
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
    // ⚠⚠ **つなぐ・切れたら予約する・数える、は通知側と同じ部品に任せる**
    // (#1252)。以前はここに #1249 で直す前の形が残っていた —— 10 回で諦めて
    // タイマーを張らず、1 回の失敗を 3 経路から数えていた。デスクトップで
    // チャットを開いたまま持ち歩くと、回線が戻っても画面を開き直すまで届かない。
    _socket?.dispose();
    _socket = ReconnectingSocket(
      buildUri: () => Uri(
        scheme: 'wss',
        host: host,
        path: '/streaming',
        queryParameters: {'i': accessToken},
      ),
      onMessage: _onMessage,
      // 購読の id は接続ごとに作り直す。
      subscribeMessage: () => jsonEncode({
        'type': 'connect',
        'body': buildConnectBody(const Uuid().v4()),
      }),
      delayFor: reconnectDelayFor,
      onStreamError: onStreamError,
      onReconnectExhausted: onReconnectExhausted,
      onConnectionEvent: onConnectionEvent,
      channelFactory: channelFactory,
      pingInterval: _pingInterval,
      connectTimeout: connectTimeout,
      stableAfter: stableConnectionAfter,
    )..connect();
    return _controller!.stream;
  }

  /// 握手を待つ上限。⚠ テストが縮める。
  Duration get connectTimeout => const Duration(seconds: 30);

  /// これだけつながり続けたら、失敗を数え直す。⚠ テストが縮める。
  Duration get stableConnectionAfter => const Duration(seconds: 30);

  /// [attempt] 回目（0 始まり）の再接続までの待ち時間。⚠ テストが上書きする。
  Duration reconnectDelayFor(int attempt) => Duration(
    milliseconds: reconnectBackoffMs(
      attempt,
      baseMs: _baseReconnectDelay.inMilliseconds,
      maxMs: _maxReconnectDelay.inMilliseconds,
      random: _random,
    ),
  );

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

  void dispose() {
    _socket?.dispose();
    _socket = null;
    _controller?.close();
    _controller = null;
  }
}

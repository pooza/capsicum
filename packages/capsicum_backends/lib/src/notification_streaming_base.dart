import 'dart:async';
import 'dart:math';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'reconnecting_socket.dart';
import 'streaming_backoff.dart';

/// notification / announcement を配信する長寿命 WebSocket 接続の共通基盤 (#676)。
///
/// Mastodon の `user` stream 用 [MastodonNotificationStreaming] と Misskey の
/// `main` channel 用 [MisskeyNotificationStreaming] で、再接続機構・定数・観測
/// コールバック・WebSocket セットアップが byte-for-byte 同一だったため集約した
/// （[MisskeyChatStreamingBase]（#627）と同じ手当て）。platform 固有なのは接続
/// URI・subscribe メッセージ・メッセージのパースの 3 点だけで、それぞれ
/// [buildStreamUri] / [buildSubscribeMessage] / [parseNotificationMessage] の
/// 抽象メソッドに切り出す。
abstract class NotificationStreamingBase {
  final String host;
  final String accessToken;
  final Set<String> adminRoleIds;

  final void Function(Object error, StackTrace stack)? onParseError;
  final void Function(Object error, StackTrace stack)? onStreamError;
  final void Function()? onReconnectExhausted;

  /// WebSocket を開く手段。null なら実際に [buildStreamUri] へ接続する。
  ///
  /// テストでローカルのサーバーへ向けるための差し替え口 (#1249)。timeline 側の
  /// `MastodonStreaming.channelFactory` (#1090) と同じ形。
  final WebSocketChannel Function(Uri uri)? channelFactory;

  /// 接続の節目（`connected` / `subscribed` / `disconnected`）を知らせる (#1252)。
  /// 語は [ReconnectingSocket] が持つ。
  final void Function(String event)? onConnectionEvent;

  StreamController<Notification>? _controller;
  ReconnectingSocket? _socket;
  final Random _random = Random();
  static const _baseReconnectDelay = Duration(seconds: 5);
  // ⚠ 上限は「回線が戻ってから通知が戻るまでに待たせる最長」になる。以前は
  // 300 秒だったが、スリープ復帰や Wi-Fi の切り替えのたびに最長 5 分通知が
  // 止まることになるので、timeline (#784) と同じ 60 秒に揃えた。
  static const _maxReconnectDelay = Duration(seconds: 60);
  // 無音切断を検知するための WS ping/pong。pong が無ければ自動 close → onDone →
  // 再接続が走る (#788)。通知は緊急性が低めなので timeline より長め。
  static const _pingInterval = Duration(seconds: 60);

  NotificationStreamingBase({
    required this.host,
    required this.accessToken,
    this.adminRoleIds = const {},
    this.onParseError,
    this.onStreamError,
    this.onReconnectExhausted,
    this.onConnectionEvent,
    this.channelFactory,
  });

  /// 接続先の WebSocket URI（platform 固有）。
  Uri buildStreamUri();

  /// 接続確立 (ready) 後に送る subscribe メッセージ（JSON 文字列）。subscribe が
  /// 不要なら null を返す（Mastodon の `user` stream は URI の `stream=user` で
  /// 購読が確定するため不要。Misskey は `main` channel への connect が要る）。
  String? buildSubscribeMessage();

  /// 1 メッセージを [Notification] へ変換する（platform 固有パース）。notification
  /// / announcement 以外は null。JSON / schema 不正は throw し、[_onMessage] 側で
  /// 観測層 ([onParseError]) に流す。
  Notification? parseNotificationMessage(String message);

  Stream<Notification> connect() {
    _controller?.close();
    _controller = StreamController<Notification>.broadcast(onCancel: dispose);
    // ⚠ つなぐ・切れたら予約する・数える、は [ReconnectingSocket] が持つ (#1252)。
    _socket?.dispose();
    _socket = ReconnectingSocket(
      buildUri: buildStreamUri,
      onMessage: _onMessage,
      subscribeMessage: buildSubscribeMessage,
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

  /// 握手を待つ上限 (#1252)。⚠ テストが縮める。
  Duration get connectTimeout => const Duration(seconds: 30);

  /// これだけつながり続けたら、失敗を数え直す (#1252)。⚠ テストが縮める。
  Duration get stableConnectionAfter => const Duration(seconds: 30);

  /// [attempt] 回目（0 始まり）の再接続までの待ち時間。
  ///
  /// ⚠ テストが上書きして、待ち時間を縮めつつ「何回目として数えたか」を読む
  /// (#1249)。本番の計算は timeline と同じ [reconnectBackoffMs]（jitter つき）。
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
      final notification = parseNotificationMessage(message);
      if (notification != null) _controller?.add(notification);
    } catch (e, st) {
      // raw payload を捨てる前に観測層へ流す (#586)。サーバー側 schema 変更や
      // fediverse_objects のパース失敗を「ストリーミング来ない」だけで気付け
      // なくなるのを避ける。
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

import 'dart:async';
import 'dart:math';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

  WebSocketChannel? _channel;
  StreamController<Notification>? _controller;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _reconnectExhaustedNotified = false;
  int _reconnectAttempts = 0;

  /// 再接続を予約済みの接続 (#1249)。1 回の失敗は `stream` の onError / onDone と
  /// `ready` の catchError の **3 経路**から届くので、同じ接続について予約するのは
  /// 1 回だけにする。⚠ これが無いと試行回数を 3 つずつ消費し、待ち時間が 1 回の
  /// 失敗ごとに 8 倍になる（実測: 0 秒 → 20 秒 → 180 秒）。
  WebSocketChannel? _reconnectScheduledFor;
  final Random _random = Random();
  // 上限 = exhausted を一度だけ通知する閾値（**give-up はしない**, #1249）。
  static const _maxReconnectAttempts = 10;
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
    _connect();
    return _controller!.stream;
  }

  void _connect() {
    if (_disposed) return;
    _channel?.sink.close();

    final uri = buildStreamUri();
    final factory = channelFactory;
    final channel = factory != null
        ? factory(uri)
        : IOWebSocketChannel.connect(uri, pingInterval: _pingInterval);
    _channel = channel;
    // listener / catchError は前世代 channel の close でも発火しうるので、
    // クロージャ捕捉した channel が現役かで判定し、旧世代の onDone / onError で
    // 余計な reconnect Timer が積まれるのを防ぐ (#548)。
    channel.stream.listen(
      _onMessage,
      onError: (Object error, StackTrace stack) {
        if (_channel != channel) return;
        _notifyStreamError(error, stack);
        _scheduleReconnect(channel);
      },
      // onDone でバックオフをリセットしない。接続直後に即 close する不調な
      // サーバーに対しリセットすると 5s 間隔のタイト再接続ループに陥り、
      // exponential backoff も exhausted 通知も効かなくなる（リセットは接続
      // 成功時の ready.then のみ）。
      onDone: () {
        if (_channel == channel) _scheduleReconnect(channel);
      },
    );

    channel.ready
        .then((_) {
          if (_disposed || _channel != channel) return;
          _reconnectAttempts = 0;
          _reconnectExhaustedNotified = false;
          final subscribe = buildSubscribeMessage();
          if (subscribe != null) channel.sink.add(subscribe);
        })
        .catchError((Object error, StackTrace stack) {
          if (_channel != channel) return;
          _notifyStreamError(error, stack);
          _scheduleReconnect(channel);
        });
  }

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

  /// [failed] が切れた / つながらなかったので、次の接続を予約する。
  void _scheduleReconnect(WebSocketChannel failed) {
    if (_disposed) return;
    // 同じ接続の失敗は 1 回だけ数える（[_reconnectScheduledFor] の説明）。
    if (identical(_reconnectScheduledFor, failed)) return;
    _reconnectScheduledFor = failed;
    // 上限に達したら exhausted を一度だけ通知する (#552)。⚠⚠ **give-up はしない**
    // (#1249)。以前はここで return してタイマーを張らなかったため、圏外が続くと
    // **回線が戻ってもアプリを起動し直すまで通知が二度と来なかった**（持ち歩いて
    // スリープと Wi-Fi の切り替えを挟むだけで起きる）。この接続は常駐する
    // デスクトップ通知の唯一の入口なので、最大間隔で試み続ける。timeline は
    // #784 で同じ方針に直してある。
    if (_reconnectAttempts >= _maxReconnectAttempts &&
        !_reconnectExhaustedNotified) {
      _reconnectExhaustedNotified = true;
      try {
        onReconnectExhausted?.call();
      } catch (_) {
        // 観測経路の失敗で本筋を止めない。
      }
    }
    _reconnectTimer?.cancel();
    final delay = reconnectDelayFor(_reconnectAttempts);
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

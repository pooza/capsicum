import 'dart:async';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 長寿命の WebSocket 1 本について、「つなぐ・切れたら次を予約する・失敗を数える」を
/// 受け持つ (#1252)。
///
/// 通知用の接続（`NotificationStreamingBase`）とチャット用の接続
/// （`MisskeyChatStreamingBase`）が、同じ作りを別々に持っていた。#1249 で通知側
/// だけを直したので、**チャット側には直す前の形（10 回で諦める・1 回の失敗を
/// 3 回数える）がそのまま残っていた**。同じ穴を 2 か所で塞がなくて済むよう、
/// 数え方と予約をここへ寄せる。
///
/// ## 守っていること
///
/// - **諦めない** (#1249)。上限に達したら [onReconnectExhausted] を 1 度だけ
///   知らせ、あとは最大間隔で試み続ける。⚠ 以前はタイマーを張らなくなり、
///   回線が戻ってもアプリを起動し直すまで何も届かなかった
/// - **1 回の失敗は 1 回だけ数える** (#1249)。失敗は `stream` の onError / onDone と
///   `ready` の catchError の 3 経路から届くので、同じ接続については 1 度だけ扱う
///   （[_handledFailureOf]）。エラーの通知も同じ 1 度に揃える
/// - **つながっただけでは数え直さない** (#1252)。握手が通った直後に切ってくる
///   相手に対して数え直すと、待ち時間が伸びず 2.5〜5 秒間隔で打ち続ける。
///   [stableAfter] のあいだつながり続けて、初めて「戻った」とみなす
/// - **握手に上限を置く** (#1252)。失敗もせず完了もしないと、失敗の 3 経路の
///   どれも走らず、次の接続が一度も予約されない（起動し直すまで来ない、が残る）
/// - **破棄したあとは何も知らせない** (#1252)
class ReconnectingSocket {
  ReconnectingSocket({
    required this.buildUri,
    required this.onMessage,
    required this.subscribeMessage,
    required this.delayFor,
    this.onStreamError,
    this.onReconnectExhausted,
    this.onConnectionEvent,
    this.channelFactory,
    this.pingInterval = const Duration(seconds: 60),
    this.connectTimeout = const Duration(seconds: 30),
    this.stableAfter = const Duration(seconds: 30),
  });

  /// 接続先。接続のたびに呼ぶ。
  final Uri Function() buildUri;

  /// 受け取った 1 通。
  final void Function(dynamic message) onMessage;

  /// 握手が通ったあとに送る購読の文面。要らなければ null を返す。接続のたびに呼ぶ
  /// （Misskey は接続ごとに購読の id を作り直す）。
  final String? Function() subscribeMessage;

  /// [attempt] 回目（0 始まり）の再接続までの待ち時間。
  final Duration Function(int attempt) delayFor;

  final void Function(Object error, StackTrace stack)? onStreamError;
  final void Function()? onReconnectExhausted;

  /// 接続の節目を知らせる (#1252)。語は [connected] / [subscribed] /
  /// [disconnected] の 3 つだけ。
  ///
  /// ⚠ 以前は**失敗したときにしか記録が出なかった**。しかも失敗の記録は圏外の
  /// 最中に送るので届かず、「この接続は生きているのか」を外から確かめる手段が
  /// 無かった（#1249 の切り分けに 1 時間以上かかった）。
  final void Function(String event)? onConnectionEvent;

  /// WebSocket を開く手段。null なら実際に接続する。テストの差し替え口。
  final WebSocketChannel Function(Uri uri)? channelFactory;

  /// 無音の切断を見つけるための ping の間隔 (#788)。
  final Duration pingInterval;

  /// 握手を待つ上限。
  final Duration connectTimeout;

  /// これだけつながり続けたら、失敗の数え直しをする。
  final Duration stableAfter;

  static const connected = 'connected';
  static const subscribed = 'subscribed';
  static const disconnected = 'disconnected';

  /// [onReconnectExhausted] を知らせる閾値。⚠ **諦める回数ではない。**
  static const exhaustedAfterAttempts = 10;

  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  Timer? _stableTimer;
  bool _disposed = false;
  bool _exhaustedNotified = false;
  int _attempts = 0;

  /// 失敗を扱い済みの接続。同じ接続の失敗を 2 度扱わないために見る。
  WebSocketChannel? _handledFailureOf;

  /// 接続を始める（または張り直す）。
  void connect() {
    if (_disposed) return;
    _stableTimer?.cancel();
    _channel?.sink.close();

    final uri = buildUri();
    final factory = channelFactory;
    final channel = factory != null
        ? factory(uri)
        : IOWebSocketChannel.connect(
            uri,
            pingInterval: pingInterval,
            connectTimeout: connectTimeout,
          );
    _channel = channel;
    // ⚠ listener / catchError は、前の世代の接続を閉じたときにも走りうる。
    // 「いまの接続か」は [_failed] の中で、捕まえた channel を見て判定する (#548)。
    channel.stream.listen(
      onMessage,
      onError: (Object error, StackTrace stack) =>
          _failed(channel, error, stack),
      // ⚠ 切れただけでは数え直さない（数え直すのは [stableAfter] のあと）。
      onDone: () => _failed(channel, null, null),
    );

    channel.ready
        // ⚠ 差し替えた接続（テスト）にも上限が効くよう、ここでも掛ける。
        .timeout(connectTimeout)
        .then((_) {
          if (_disposed || _channel != channel) return;
          _notifyEvent(connected);
          _stableTimer = Timer(stableAfter, () {
            if (_disposed || _channel != channel) return;
            _attempts = 0;
            _exhaustedNotified = false;
          });
          final subscribe = subscribeMessage();
          if (subscribe != null) {
            channel.sink.add(subscribe);
            _notifyEvent(subscribed);
          }
        })
        .catchError((Object error, StackTrace stack) {
          _failed(channel, error, stack);
        });
  }

  /// [channel] が切れた / つながらなかった。[error] は切断だけなら null。
  void _failed(WebSocketChannel channel, Object? error, StackTrace? stack) {
    if (_disposed) return;
    if (_channel != channel) return;
    if (identical(_handledFailureOf, channel)) return;
    _handledFailureOf = channel;
    _stableTimer?.cancel();

    if (error != null) {
      try {
        onStreamError?.call(error, stack ?? StackTrace.current);
      } catch (_) {
        // 観測経路の失敗で本筋を止めない。
      }
    }
    _notifyEvent(disconnected);

    if (_attempts >= exhaustedAfterAttempts && !_exhaustedNotified) {
      _exhaustedNotified = true;
      try {
        onReconnectExhausted?.call();
      } catch (_) {
        // 観測経路の失敗で本筋を止めない。
      }
    }
    _reconnectTimer?.cancel();
    final delay = delayFor(_attempts);
    _attempts++;
    _reconnectTimer = Timer(delay, () {
      if (!_disposed) connect();
    });
  }

  void _notifyEvent(String event) {
    try {
      onConnectionEvent?.call(event);
    } catch (_) {
      // 観測経路の失敗で本筋を止めない。
    }
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _stableTimer?.cancel();
    _channel?.sink.close();
  }
}

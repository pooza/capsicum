import 'dart:async';
import 'dart:math';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'streaming_backoff.dart';

/// 再接続の値の組 (#1340)。
///
/// ⚠⚠ **2 種類あるのは意図したもの**（2026-10-27 pooza 判断・#1340）。値を
/// 揃えるのではなく、4 本（通知・チャット・タイムライン 2 本）が写していた値と
/// 配線をここへ寄せた。上限はどちらも 60 秒（以前の 300 秒はスリープ復帰や
/// Wi-Fi の切り替えのたびに最長 5 分止まった・#784 / #1252）。
class ReconnectProfile {
  const ReconnectProfile({
    required this.baseDelay,
    required this.maxDelay,
    required this.pingInterval,
  });

  /// 1 回目の再接続までの待ち（jitter で半分〜この値）。
  final Duration baseDelay;

  /// 再接続の待ちの上限。⚠ 「回線が戻ってから届き始めるまでに待たせる最長」になる。
  final Duration maxDelay;

  /// 無音の切断を見つけるための ping の間隔 (#788)。NAT / プロキシのアイドル切断
  /// では FIN / RST が来ず onDone / onError が発火しないので、pong が無ければ
  /// dart:io が閉じる → 再接続、で拾う。検知までの時間 ≒ この値。
  final Duration pingInterval;

  /// 即時: タイムライン。初動は速く（瞬間 503 / 瞬断から数秒で戻る）、ping も
  /// 短い（実況で使う本線なので、切れたまま座り続けない）。
  static const live = ReconnectProfile(
    baseDelay: Duration(seconds: 1),
    maxDelay: Duration(seconds: 60),
    pingInterval: Duration(seconds: 30),
  );

  /// 常駐: 通知・チャット。タイムラインより緊急性が低めなので長め。
  ///
  /// ⚠ デスクトップでは通知のストリーミングがそのままプッシュ通知の経路なので、
  /// 「緊急性が低め」はモバイルでしか成り立たない。それを確かめたうえで、通知も
  /// この値にしている（#1340・2026-10-27 pooza 判断）。
  static const resident = ReconnectProfile(
    baseDelay: Duration(seconds: 5),
    maxDelay: Duration(seconds: 60),
    pingInterval: Duration(seconds: 60),
  );
}

/// [ReconnectingSocket] に渡す時間の取り決め (#1340)。
///
/// 以前は 4 本がそれぞれ定数と getter を写していた。⚠ getter はテストが上書きして
/// 縮めるので、名前を変えずに残している。
mixin ReconnectTuning {
  /// どちらの値の組で再接続するか。
  ReconnectProfile get reconnectProfile;

  final Random _reconnectRandom = Random();

  /// 握手を待つ上限 (#1252)。⚠ テストが縮める。
  Duration get connectTimeout => const Duration(seconds: 30);

  /// これだけつながり続けたら、失敗を数え直す (#1252)。⚠ テストが縮める。
  Duration get stableConnectionAfter => const Duration(seconds: 30);

  /// [attempt] 回目（0 始まり）の再接続までの待ち時間（jitter つき・#784）。
  ///
  /// ⚠ テストが上書きして、待ち時間を縮めつつ「何回目として数えたか」を読む
  /// (#1249)。
  Duration reconnectDelayFor(int attempt) => Duration(
    milliseconds: reconnectBackoffMs(
      attempt,
      baseMs: reconnectProfile.baseDelay.inMilliseconds,
      maxMs: reconnectProfile.maxDelay.inMilliseconds,
      random: _reconnectRandom,
    ),
  );
}

/// タイムラインの 2 本（Mastodon / Misskey）が持つ、接続の節目を
/// [StreamConnectionState] へ写す分岐 (#714 / #1340)。
///
/// 2 本が同じ分岐を写していたので寄せた。⚠ 同じ状態が続くときは UI へ重ねて
/// 知らせない。観測経路の失敗で本筋を止めない。
mixin StreamConnectionStateReporter {
  void Function(StreamConnectionState state)? get onConnectionState;

  /// 破棄したあとは知らせない。
  bool get isStreamDisposed;

  StreamConnectionState? _lastConnectionState;

  void notifyConnectionState(StreamConnectionState next) {
    if (isStreamDisposed || _lastConnectionState == next) return;
    _lastConnectionState = next;
    try {
      onConnectionState?.call(next);
    } catch (_) {}
  }

  /// [ReconnectingSocket.onConnectionEvent] に渡す。
  void reportConnectionEvent(String event) {
    if (event == ReconnectingSocket.connected) {
      notifyConnectionState(StreamConnectionState.live);
    } else if (event == ReconnectingSocket.disconnected) {
      notifyConnectionState(StreamConnectionState.disconnected);
    }
  }

  /// [ReconnectingSocket.onReconnectExhausted] に渡す。呼び出し側の
  /// [onReconnectExhausted] を知らせてから、状態を `exhausted` にする。
  void Function() reportExhausted(void Function()? onReconnectExhausted) => () {
    try {
      onReconnectExhausted?.call();
    } catch (_) {
      // 観測経路の失敗で本筋を止めない。
    }
    notifyConnectionState(StreamConnectionState.exhausted);
  };
}

/// 長寿命の WebSocket 1 本について、「つなぐ・切れたら次を予約する・失敗を数える」を
/// 受け持つ (#1252)。
///
/// 通知用の接続（`NotificationStreamingBase`）とチャット用の接続
/// （`MisskeyChatStreamingBase`）が、同じ作りを別々に持っていた。#1249 で通知側
/// だけを直したので、**チャット側には直す前の形（10 回で諦める・1 回の失敗を
/// 3 回数える）がそのまま残っていた**。同じ穴を 2 か所で塞がなくて済むよう、
/// 数え方と予約をここへ寄せる。
///
/// 載っているのは 4 本: 通知（`NotificationStreamingBase`）・チャット
/// （`MisskeyChatStreamingBase`）・タイムライン（`MastodonStreaming` /
/// `MisskeyStreaming`・#1265）。⚠ タイムラインの 2 本は v2.5 まで自前の再接続の
/// ままで、握手の上限が無く（宙づりになると起動し直すまで更新が来ない）、1 回の
/// 失敗を最大 3 回数えていた。
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
    required this.subscribeMessages,
    required this.delayFor,
    this.onStreamError,
    this.onReconnectExhausted,
    this.onConnectionEvent,
    this.onConnecting,
    this.onClosed,
    this.channelFactory,
    this.pingInterval = const Duration(seconds: 60),
    this.connectTimeout = const Duration(seconds: 30),
    this.stableAfter = const Duration(seconds: 30),
  });

  /// 時間の取り決めを [tuning] から取る (#1340)。4 本はこちらを使う。
  ReconnectingSocket.tuned(
    ReconnectTuning tuning, {
    required Uri Function() buildUri,
    required void Function(dynamic message) onMessage,
    required List<String> Function() subscribeMessages,
    void Function(Object error, StackTrace stack)? onStreamError,
    void Function()? onReconnectExhausted,
    void Function(String event)? onConnectionEvent,
    void Function()? onConnecting,
    void Function(int? closeCode, String? closeReason)? onClosed,
    WebSocketChannel Function(Uri uri)? channelFactory,
  }) : this(
         buildUri: buildUri,
         onMessage: onMessage,
         subscribeMessages: subscribeMessages,
         delayFor: tuning.reconnectDelayFor,
         onStreamError: onStreamError,
         onReconnectExhausted: onReconnectExhausted,
         onConnectionEvent: onConnectionEvent,
         onConnecting: onConnecting,
         onClosed: onClosed,
         channelFactory: channelFactory,
         pingInterval: tuning.reconnectProfile.pingInterval,
         connectTimeout: tuning.connectTimeout,
         stableAfter: tuning.stableConnectionAfter,
       );

  /// 接続先。接続のたびに呼ぶ。
  final Uri Function() buildUri;

  /// 受け取った 1 通。
  final void Function(dynamic message) onMessage;

  /// 握手が通ったあとに送る購読の文面。要らなければ空を返す。接続のたびに呼ぶ
  /// （Misskey は接続ごとに購読の id を作り直す）。
  ///
  /// ⚠ 複数あるのは Mastodon の複数タグの購読 (#1277)。`hashtag` ストリームは
  /// タグ 1 つしか受けないので、1 本の接続にタグごとの購読を載せる。
  final List<String> Function() subscribeMessages;

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

  /// 接続を始める直前（張り直しも含む）。タイムラインの「接続中」の表示と、
  /// 接続ごとに空にする状態のため (#1265)。
  final void Function()? onConnecting;

  /// 相手から閉じられた（エラーではない切断）。WebSocket の closeCode /
  /// closeReason を渡す (#788 / #1265)。同じ接続については 1 度だけ。
  final void Function(int? closeCode, String? closeReason)? onClosed;

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
    try {
      onConnecting?.call();
    } catch (_) {
      // 観測経路の失敗で本筋を止めない。
    }

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
    // ⚠ メッセージも世代で見る (#1340)。閉じた古い接続にバッファが残っていると、
    // 置き換えた後にも届く（受け手の重複除去で実害は出ていない）。
    channel.stream.listen(
      (message) {
        if (_disposed || _channel != channel) return;
        onMessage(message);
      },
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
          // ⚠ 握手が成立した直後に、切断のほうが先に処理されていることがある
          // (#1267)。そのまま進むと、失敗のあとに安定タイマーを張り、張り直しを
          // 待っている間に試行回数が 0 へ戻る（バックオフが効かなくなる）。
          // 「つながった」の記録も、切れたあとに出すことになる。
          if (identical(_handledFailureOf, channel)) return;
          _notifyEvent(connected);
          _stableTimer = Timer(stableAfter, () {
            if (_disposed || _channel != channel) return;
            if (identical(_handledFailureOf, channel)) return;
            _attempts = 0;
            _exhaustedNotified = false;
          });
          final subscribes = subscribeMessages();
          for (final subscribe in subscribes) {
            channel.sink.add(subscribe);
          }
          if (subscribes.isNotEmpty) _notifyEvent(subscribed);
        })
        .catchError((Object error, StackTrace stack) {
          _failed(channel, error, stack);
        });
  }

  /// いまの接続を閉じ、切れたときと同じ規則で張り直す (#1353)。
  ///
  /// ⚠ [connect] を直接呼ばない。待ち時間と失敗の数え方を通さないと、断り続ける
  /// 相手へ打ち続ける。
  void closeAndRetry() {
    final channel = _channel;
    if (_disposed || channel == null) return;
    channel.sink.close();
    _failed(channel, null, null);
  }

  /// [channel] が切れた / つながらなかった。[error] は切断だけなら null。
  void _failed(WebSocketChannel channel, Object? error, StackTrace? stack) {
    if (_disposed) return;
    if (_channel != channel) return;
    if (identical(_handledFailureOf, channel)) return;
    _handledFailureOf = channel;
    _stableTimer?.cancel();

    try {
      if (error != null) {
        onStreamError?.call(error, stack ?? StackTrace.current);
      } else {
        // エラーが無いのは onDone（相手から閉じられた）だけ。
        onClosed?.call(channel.closeCode, channel.closeReason);
      }
    } catch (_) {
      // 観測経路の失敗で本筋を止めない。
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

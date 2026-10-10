import 'dart:async';
import 'dart:io';

import 'package:capsicum_backends/src/notification_streaming_base.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

/// #1249: 通知用の接続は、圏外が続いても再接続を諦めない。
///
/// ⚠⚠ 以前は 10 回で諦めてタイマーを張らなくなり、**回線が戻ってもアプリを
/// 起動し直すまで通知が来なかった**。しかも 1 回の失敗を 3 回ぶん数えていた
/// （`stream` の onError / onDone と `ready` の catchError）ので、実際には 5 回・
/// 約 13 分で尽きた。持ち歩いてスリープと Wi-Fi の切り替えを挟むだけで起きる。
///
/// ⚠ それまで通知側の接続を固定するテストは 1 本も無かった（パースだけ）。
/// ここでは**実際にローカルのポートへつなぎにいき**、拒否されたときの数え方と、
/// サーバーが戻ったときの復帰を見る。
void main() {
  /// 空いているポートを取ってすぐ閉じる ＝ 以後の接続は必ず拒否される。
  Future<int> closedPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  /// [condition] が真になるまで待つ（最長 5 秒）。
  Future<void> waitUntil(bool Function() condition) async {
    for (var i = 0; i < 500 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('⚠⚠ 1 回の失敗は 1 回だけ数える（3 経路から届いても）', () async {
    final probe = _Probe(await closedPort());
    final sub = probe.connect().listen((_) {});
    addTearDown(sub.cancel);

    await waitUntil(() => probe.delayRequests.length >= 6);
    // ⚠ 2 つの値は**同じ瞬間に**控える (#1252)。待ち 5ms に対して確認の間隔が
    // 10ms なので、別々に読むとその間に次の接続が走り、上限を絶対値で書くと
    // 余裕が無かった。見たいのは「1 対 1 で並ぶ」ことなので、関係で書く。
    final delays = probe.delayRequests.length;
    final connects = probe.connectCount;

    // 接続を試みた回数と、待ち時間を求めた回数が 1 対 1 で並ぶ。以前は 1 回の
    // 失敗で 3 回求めていたので、[0, 1, 2, 3, 4, 5] ではなく [0, 1, 2] の時点で
    // 接続は 1 回しか試みていなかった。
    expect(probe.delayRequests.take(6), [0, 1, 2, 3, 4, 5]);
    expect(
      connects,
      inInclusiveRange(delays, delays + 1),
      reason: '失敗 1 回につき待ち時間を 1 回求める（次の 1 回が走り出していてもよい）',
    );
  });

  test('⚠⚠ 上限を超えても諦めない・exhausted は 1 回だけ知らせる', () async {
    var exhausted = 0;
    final probe = _Probe(
      await closedPort(),
      onReconnectExhausted: () => exhausted++,
    );
    final sub = probe.connect().listen((_) {});
    addTearDown(sub.cancel);

    // 上限は 10 回。それを大きく超えるまで試み続けること。
    await waitUntil(() => probe.connectCount >= 25);

    expect(probe.connectCount, greaterThanOrEqualTo(25), reason: '止まらない');
    expect(exhausted, 1, reason: '観測への通知は一度きり');
  });

  test('⚠⚠ 諦めたはずの回数を過ぎてからサーバーが戻っても、つながって購読を送る', () async {
    final port = await closedPort();
    final probe = _Probe(port, subscribe: 'hello');
    final sub = probe.connect().listen((_) {});
    addTearDown(sub.cancel);

    // 旧実装が諦めていた回数（10）を確実に過ぎるまで失敗させる。
    await waitUntil(() => probe.connectCount >= 15);
    expect(probe.connectCount, greaterThanOrEqualTo(15), reason: '前提');

    // 同じポートでサーバーを立てる ＝ 回線が戻った。
    final received = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((message) => received.add(message as String));
    });

    await waitUntil(() => received.isNotEmpty);
    expect(received, ['hello'], reason: 'つなぎ直して購読を送っている');
  });

  test('つながったら数え直す（次に切れたときは 0 回目から）', () async {
    final port = await closedPort();
    final probe = _Probe(port);
    final sub = probe.connect().listen((_) {});
    addTearDown(sub.cancel);

    await waitUntil(() => probe.delayRequests.length >= 3);

    final sockets = <WebSocket>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      sockets.add(await WebSocketTransformer.upgrade(request));
    });
    await waitUntil(() => sockets.isNotEmpty);
    expect(sockets, isNotEmpty, reason: '前提: つながった');
    // ready の完了がクライアント側へ届くのを待つ。
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final before = probe.delayRequests.length;
    await sockets.first.close();
    await waitUntil(() => probe.delayRequests.length > before);

    expect(probe.delayRequests[before], 0, reason: '成功をはさんだので 0 回目から');
  });

  // ---- #1252: v2.0.1 のレビューで送られた分 ----

  test('⚠⚠ つながっては切ってくる相手には、数え直さず待ち時間を伸ばす', () async {
    final port = await closedPort();
    // ⚠ 「つながり続けた」とみなすまでを長く取る ＝ すぐ切られる限り数え直さない。
    final probe = _Probe(port, stableAfter: const Duration(seconds: 30));
    final sub = probe.connect().listen((_) {});
    addTearDown(sub.cancel);

    // 握手は通すが、通した直後に切るサーバー。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await socket.close();
    });

    await waitUntil(() => probe.delayRequests.length >= 5);
    final tail = probe.delayRequests.sublist(probe.delayRequests.length - 4);
    expect(
      tail.toSet().length,
      4,
      reason: '⚠ 直す前は握手のたびに 0 へ戻り、[0, 0, 0, 0] で打ち続けていた: $tail',
    );
    expect(tail.last, greaterThanOrEqualTo(3));
  });

  test('⚠⚠ 握手が失敗も完了もしなくても、次の接続を予約する', () async {
    // TCP は受けるが、WebSocket の握手に何も返さないサーバー。
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final held = <Socket>[];
    silent.listen(held.add);
    addTearDown(() async {
      for (final s in held) {
        s.destroy();
      }
      await silent.close();
    });

    final errors = <Object>[];
    final probe = _Probe(
      silent.port,
      connectTimeout: const Duration(milliseconds: 50),
      onStreamError: (e, _) => errors.add(e),
    );
    final sub = probe.connect().listen((_) {});
    addTearDown(sub.cancel);

    await waitUntil(() => probe.connectCount >= 3);
    expect(
      probe.connectCount,
      greaterThanOrEqualTo(3),
      reason: '⚠ 直す前は 1 回つなぎにいったきり、何も起きなかった',
    );
    expect(errors, isNotEmpty, reason: '時間切れを失敗として知らせている');
  });

  test('⚠ 1 回の失敗につき、エラーの通知は 1 回', () async {
    final errors = <Object>[];
    final probe = _Probe(
      await closedPort(),
      onStreamError: (e, _) => errors.add(e),
    );
    final sub = probe.connect().listen((_) {});
    addTearDown(sub.cancel);

    await waitUntil(() => probe.delayRequests.length >= 5);
    final delays = probe.delayRequests.length;
    final notified = errors.length;
    expect(
      notified,
      inInclusiveRange(delays - 1, delays + 1),
      reason: '⚠ 直す前は 1 回の失敗で 2 回届いていた（onError と catchError）',
    );
  });

  test('⚠ 破棄したあとは、接続もエラーの通知もしない', () async {
    final errors = <Object>[];
    final probe = _Probe(
      await closedPort(),
      onStreamError: (e, _) => errors.add(e),
    );
    final sub = probe.connect().listen((_) {});
    await waitUntil(() => probe.connectCount >= 3);

    await sub.cancel(); // broadcast の onCancel が dispose を呼ぶ。
    final connects = probe.connectCount;
    final notified = errors.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(probe.connectCount, connects, reason: 'タイマーが止まっている');
    expect(errors.length, notified, reason: '破棄のあとに通知が届かない');
  });

  test('接続の節目を知らせる（つながった・購読した・切れた）', () async {
    final port = await closedPort();
    final events = <String>[];
    final probe = _Probe(
      port,
      subscribe: 'hello',
      onConnectionEvent: events.add,
    );
    final sub = probe.connect().listen((_) {});
    addTearDown(sub.cancel);

    final sockets = <WebSocket>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      sockets.add(await WebSocketTransformer.upgrade(request));
    });
    await waitUntil(() => events.contains('subscribed'));
    await sockets.first.close();
    await waitUntil(
      () => events.lastIndexOf('disconnected') > events.indexOf('subscribed'),
    );

    final from = events.indexOf('connected');
    expect(from, greaterThanOrEqualTo(0), reason: '前提: つながった');
    expect(events.sublist(from, from + 3), [
      'connected',
      'subscribed',
      'disconnected',
    ]);
  });

  test('本番の待ち時間は 60 秒で頭打ち（5 分待たせない）', () {
    final streaming = _Production();
    for (final attempt in [0, 3, 10, 100]) {
      expect(
        streaming.reconnectDelayFor(attempt),
        lessThanOrEqualTo(const Duration(seconds: 60)),
        reason: 'attempt=$attempt',
      );
    }
    // 初動は 5 秒（jitter で 2.5〜5 秒）。
    expect(
      streaming.reconnectDelayFor(0).inMilliseconds,
      inInclusiveRange(2500, 5000),
    );
  });
}

/// 待ち時間を 5ms に縮め、「何回目として数えたか」と接続の回数を記録する。
class _Probe extends NotificationStreamingBase {
  _Probe(
    int port, {
    this.subscribe,
    this.stableAfter = const Duration(milliseconds: 20),
    Duration connectTimeout = const Duration(seconds: 5),
    super.onReconnectExhausted,
    super.onStreamError,
    super.onConnectionEvent,
  }) : _connectTimeout = connectTimeout,
       super(
         host: '127.0.0.1',
         accessToken: 'token',
         channelFactory: (uri) => IOWebSocketChannel.connect(
           Uri.parse('ws://127.0.0.1:$port/streaming'),
         ),
       );

  final String? subscribe;
  final delayRequests = <int>[];
  int connectCount = 0;

  /// 「つながり続けた」とみなすまで。⚠ 既定は短くしてある（成功をはさんだら
  /// 数え直す、を見るテストが待てるように）。
  final Duration stableAfter;
  final Duration _connectTimeout;

  @override
  Duration get stableConnectionAfter => stableAfter;

  @override
  Duration get connectTimeout => _connectTimeout;

  @override
  Uri buildStreamUri() {
    connectCount++;
    return Uri.parse('wss://example.invalid/streaming');
  }

  @override
  String? buildSubscribeMessage() => subscribe;

  @override
  Notification? parseNotificationMessage(String message) => null;

  @override
  Duration reconnectDelayFor(int attempt) {
    delayRequests.add(attempt);
    return const Duration(milliseconds: 5);
  }
}

/// 本番の待ち時間の計算だけを読むための最小の実装（接続はしない）。
class _Production extends NotificationStreamingBase {
  _Production()
    : super(
        host: 'example.invalid',
        accessToken: 'token',
        channelFactory: (_) => throw UnimplementedError(),
      );

  @override
  Uri buildStreamUri() => Uri.parse('wss://example.invalid/streaming');

  @override
  String? buildSubscribeMessage() => null;

  @override
  Notification? parseNotificationMessage(String message) => null;
}

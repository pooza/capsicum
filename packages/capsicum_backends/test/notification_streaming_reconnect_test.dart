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

    // 接続を試みた回数と、待ち時間を求めた回数が 1 対 1 で並ぶ。以前は 1 回の
    // 失敗で 3 回求めていたので、[0, 1, 2, 3, 4, 5] ではなく [0, 1, 2] の時点で
    // 接続は 1 回しか試みていなかった。
    expect(probe.delayRequests.take(6), [0, 1, 2, 3, 4, 5]);
    expect(
      probe.connectCount,
      inInclusiveRange(6, 7),
      reason: '待ち時間を 6 回求めた ＝ 6 回失敗した（7 回目が走り出していてもよい）',
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
  _Probe(int port, {this.subscribe, super.onReconnectExhausted})
    : super(
        host: '127.0.0.1',
        accessToken: 'token',
        channelFactory: (uri) => IOWebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:$port/streaming'),
        ),
      );

  final String? subscribe;
  final delayRequests = <int>[];
  int connectCount = 0;

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

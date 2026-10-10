import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:capsicum_backends/src/misskey/chat_streaming_base.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

/// #1252: チャットの接続にも、通知側（#1249）と同じ「諦めない」を入れる。
///
/// ⚠⚠ 直す前のチャット側は、#1249 で直す前の通知側と同じ形だった —— 10 回で
/// 諦めてタイマーを張らず、1 回の失敗を 3 経路（`stream` の onError / onDone と
/// `ready` の catchError）から数えていた。デスクトップでチャットを開いたまま
/// 持ち歩くと、回線が戻っても画面を開き直すまでメッセージが届かない。
///
/// 数え方と予約は通知側と同じ部品（`ReconnectingSocket`）に任せたので、細かい
/// 振る舞いは `notification_streaming_reconnect_test.dart` が見ている。ここでは
/// **チャット側がその部品に載っていること**を、実際の接続で確かめる。
void main() {
  Future<int> closedPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<void> waitUntil(bool Function() condition) async {
    for (var i = 0; i < 500 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('⚠⚠ 1 回の失敗は 1 回だけ数える', () async {
    final probe = _Probe(await closedPort());
    final sub = probe.connect().listen((_) {});
    addTearDown(sub.cancel);

    await waitUntil(() => probe.delayRequests.length >= 6);
    expect(probe.delayRequests.take(6), [
      0,
      1,
      2,
      3,
      4,
      5,
    ], reason: '⚠ 直す前は 1 回の失敗で試行回数を 3 つ消費していた');
  });

  test('⚠⚠ 上限を超えても諦めない・exhausted は 1 回だけ知らせる', () async {
    var exhausted = 0;
    final probe = _Probe(
      await closedPort(),
      onReconnectExhausted: () => exhausted++,
    );
    final sub = probe.connect().listen((_) {});
    addTearDown(sub.cancel);

    await waitUntil(() => probe.delayRequests.length >= 25);
    expect(
      probe.delayRequests.length,
      greaterThanOrEqualTo(25),
      reason: '⚠ 直す前は 10 回で止まり、二度とつなぎにいかなかった',
    );
    expect(exhausted, 1);
  });

  test('⚠⚠ 諦めたはずの回数を過ぎてからサーバーが戻っても、購読を送り直す', () async {
    final port = await closedPort();
    final probe = _Probe(port);
    final sub = probe.connect().listen((_) {});
    addTearDown(sub.cancel);

    await waitUntil(() => probe.delayRequests.length >= 15);
    expect(probe.delayRequests.length, greaterThanOrEqualTo(15), reason: '前提');

    final received = <Map<String, dynamic>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(
        (message) =>
            received.add(jsonDecode(message as String) as Map<String, dynamic>),
      );
    });

    await waitUntil(() => received.isNotEmpty);
    expect(received, isNotEmpty, reason: 'つなぎ直している');
    expect(received.first['type'], 'connect');
    expect((received.first['body'] as Map)['channel'], 'probe');
  });

  test('本番の待ち時間は 60 秒で頭打ち（以前は 5 分）', () {
    final streaming = _Production();
    for (final attempt in [0, 3, 10, 100]) {
      expect(
        streaming.reconnectDelayFor(attempt),
        lessThanOrEqualTo(const Duration(seconds: 60)),
        reason: 'attempt=$attempt',
      );
    }
  });
}

class _Probe extends MisskeyChatStreamingBase {
  _Probe(int port, {super.onReconnectExhausted})
    : super(
        host: '127.0.0.1',
        accessToken: 'token',
        channelFactory: (uri) => IOWebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:$port/streaming'),
        ),
      );

  final delayRequests = <int>[];

  @override
  Map<String, dynamic> buildConnectBody(String subscriptionId) => {
    'channel': 'probe',
    'id': subscriptionId,
  };

  @override
  ChatMessage? parseChannelMessage(Map<String, dynamic> body) => null;

  @override
  Duration get stableConnectionAfter => const Duration(milliseconds: 20);

  @override
  Duration reconnectDelayFor(int attempt) {
    delayRequests.add(attempt);
    return const Duration(milliseconds: 5);
  }
}

class _Production extends MisskeyChatStreamingBase {
  _Production()
    : super(
        host: 'example.invalid',
        accessToken: 'token',
        channelFactory: (_) => throw UnimplementedError(),
      );

  @override
  Map<String, dynamic> buildConnectBody(String subscriptionId) => const {};

  @override
  ChatMessage? parseChannelMessage(Map<String, dynamic> body) => null;
}

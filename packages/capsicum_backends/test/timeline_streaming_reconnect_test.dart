import 'dart:async';
import 'dart:io';

import 'package:capsicum_backends/src/mastodon/streaming.dart';
import 'package:capsicum_backends/src/misskey/streaming.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/refusing_port.dart';

/// #1265: タイムラインのストリーミングの再接続を `ReconnectingSocket` に寄せた。
///
/// ⚠⚠ 通知とチャット（#1252）だけを寄せ、タイムラインの 2 本は自前の再接続の
/// ままだった。**握手に上限が無く**、宙づりになると起動し直すまで更新が来ず、
/// **1 回の失敗を最大 3 回数えて**「接続が不安定」の表示に早く達していた。
///
/// 実際にローカルのポートへつなぎにいく（通知側の
/// `notification_streaming_reconnect_test.dart` と同じ作り）。
void main() {
  Future<RefusingPort> refusingPort() async {
    final refusing = await RefusingPort.open();
    addTearDown(refusing.close);
    return refusing;
  }

  /// [condition] が真になるまで待つ（最長 5 秒）。
  Future<void> waitUntil(bool Function() condition) async {
    for (var i = 0; i < 500 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  for (final backend in _Backend.values) {
    group(backend.name, () {
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
          backend,
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

      test('⚠⚠ 1 回の失敗は 1 回だけ数える（3 経路から届いても）', () async {
        final probe = _Probe(backend, (await refusingPort()).port);
        final sub = probe.connect().listen((_) {});
        addTearDown(sub.cancel);

        await waitUntil(() => probe.delayRequests.length >= 6);
        // ⚠ 2 つの値は同じ瞬間に控える（通知側のテストと同じ理由）。
        final delays = probe.delayRequests.length;
        final connects = probe.connectCount;

        expect(probe.delayRequests.take(6), [0, 1, 2, 3, 4, 5]);
        expect(
          connects,
          inInclusiveRange(delays, delays + 1),
          reason: '失敗 1 回につき待ち時間を 1 回求める（次の 1 回が走り出していてもよい）',
        );
      });

      test('⚠ 上限を超えても諦めず、exhausted の表示と通知は 1 回だけ', () async {
        var exhausted = 0;
        final states = <StreamConnectionState>[];
        final probe = _Probe(
          backend,
          (await refusingPort()).port,
          onReconnectExhausted: () => exhausted++,
          onConnectionState: states.add,
        );
        final sub = probe.connect().listen((_) {});
        addTearDown(sub.cancel);

        await waitUntil(() => probe.connectCount >= 15);

        expect(probe.connectCount, greaterThanOrEqualTo(15), reason: '止まらない');
        expect(exhausted, 1);
        expect(
          states.where((s) => s == StreamConnectionState.exhausted),
          hasLength(1),
        );
        expect(states.first, StreamConnectionState.connecting);
        expect(states, isNot(contains(StreamConnectionState.live)));
      });

      test('つながったら live、相手から閉じたら closeCode を 1 回だけ渡して disconnected', () async {
        final refusing = await refusingPort();
        final port = refusing.port;
        final states = <StreamConnectionState>[];
        final closes = <int?>[];
        final probe = _Probe(
          backend,
          port,
          onConnectionState: states.add,
          onDisconnect: (code, _) => closes.add(code),
        );
        final sub = probe.connect().listen((_) {});
        addTearDown(sub.cancel);

        await refusing.close();
        final sockets = <WebSocket>[];
        final server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          sockets.add(await WebSocketTransformer.upgrade(request));
        });
        await waitUntil(
          () =>
              states.contains(StreamConnectionState.live) && sockets.isNotEmpty,
        );
        expect(states, contains(StreamConnectionState.live), reason: '前提');

        await sockets.first.close(4000, 'bye');
        await waitUntil(() => closes.isNotEmpty);
        // 次の接続が走って同じ相手にまたつながっても、閉じた記録は 1 回ぶん。
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(closes, [4000]);
        expect(
          states.sublist(states.indexOf(StreamConnectionState.live)),
          containsAllInOrder([
            StreamConnectionState.live,
            StreamConnectionState.disconnected,
            StreamConnectionState.connecting,
          ]),
        );
      });

      test('⚠ 破棄したあとは、接続もエラーの通知もしない', () async {
        final errors = <Object>[];
        final probe = _Probe(
          backend,
          (await refusingPort()).port,
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
    });
  }
}

enum _Backend { mastodon, misskey }

/// 待ち時間を 5ms に縮め、「何回目として数えたか」と接続の回数を記録する。
class _Probe {
  _Probe(
    this.backend,
    int port, {
    Duration connectTimeout = const Duration(seconds: 5),
    void Function()? onReconnectExhausted,
    void Function(Object, StackTrace)? onStreamError,
    void Function(StreamConnectionState)? onConnectionState,
    void Function(int?, String?)? onDisconnect,
  }) {
    WebSocketChannel factory(Uri _) {
      connectCount++;
      return IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port/'));
    }

    _connect = switch (backend) {
      _Backend.mastodon => _MastodonProbe(
        this,
        connectTimeout,
        onReconnectExhausted: onReconnectExhausted,
        onStreamError: onStreamError,
        onConnectionState: onConnectionState,
        onDisconnect: onDisconnect,
        channelFactory: factory,
      ).connect,
      _Backend.misskey => _MisskeyProbe(
        this,
        connectTimeout,
        onReconnectExhausted: onReconnectExhausted,
        onStreamError: onStreamError,
        onConnectionState: onConnectionState,
        onDisconnect: onDisconnect,
        channelFactory: factory,
      ).connect,
    };
  }

  final _Backend backend;
  final delayRequests = <int>[];
  int connectCount = 0;
  late final Stream<Post> Function(TabType) _connect;

  Stream<Post> connect() => _connect(const TimelineTab(TimelineType.home));

  Duration delayFor(int attempt) {
    delayRequests.add(attempt);
    return const Duration(milliseconds: 5);
  }
}

class _MastodonProbe extends MastodonStreaming {
  _MastodonProbe(
    this.probe,
    this._connectTimeout, {
    super.onReconnectExhausted,
    super.onStreamError,
    super.onConnectionState,
    super.onDisconnect,
    super.channelFactory,
  }) : super(host: 'example.invalid', accessToken: 'token');

  final _Probe probe;
  final Duration _connectTimeout;

  @override
  Duration get connectTimeout => _connectTimeout;

  @override
  Duration get stableConnectionAfter => const Duration(milliseconds: 20);

  @override
  Duration reconnectDelayFor(int attempt) => probe.delayFor(attempt);
}

class _MisskeyProbe extends MisskeyStreaming {
  _MisskeyProbe(
    this.probe,
    this._connectTimeout, {
    super.onReconnectExhausted,
    super.onStreamError,
    super.onConnectionState,
    super.onDisconnect,
    super.channelFactory,
  }) : super(host: 'example.invalid', accessToken: 'token');

  final _Probe probe;
  final Duration _connectTimeout;

  @override
  Duration get connectTimeout => _connectTimeout;

  @override
  Duration get stableConnectionAfter => const Duration(milliseconds: 20);

  @override
  Duration reconnectDelayFor(int attempt) => probe.delayFor(attempt);
}

import 'dart:async';

import 'package:capsicum_backends/src/reconnecting_socket.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// #1267: 握手の成立より先に切断が処理された接続を、「つながった」として
/// 扱わない。
///
/// 握手（`ready`）の完了と、ストリームの終了（`onDone`）は別々に届く。切断が先に
/// 処理されると、失敗を扱ったあとで `ready.then` が走り、**安定タイマーを張って
/// 試行回数を 0 へ戻しうる**（バックオフが効かなくなる）。
class _FakeSink implements WebSocketSink {
  final List<Object?> sent = [];

  @override
  void add(Object? data) => sent.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChannel implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  final readyCompleter = Completer<void>();
  final _sink = _FakeSink();

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  Future<void> get ready => readyCompleter.future;

  @override
  WebSocketSink get sink => _sink;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('⚠⚠ 切断が先に処理された接続は、あとから握手が成立しても数え直さない', () {
    fakeAsync((async) {
      final channels = <_FakeChannel>[];
      final events = <String>[];
      final delays = <int>[];
      final socket = ReconnectingSocket(
        buildUri: () => Uri.parse('ws://example.invalid/'),
        onMessage: (_) {},
        subscribeMessages: () => ['subscribe'],
        delayFor: (attempt) {
          delays.add(attempt);
          // 安定とみなす時間（1 秒）より長く待つ ＝ 待っている間に、誤って張られた
          // 安定タイマーが発火しうる。
          return const Duration(seconds: 5);
        },
        onConnectionEvent: events.add,
        channelFactory: (_) {
          final channel = _FakeChannel();
          channels.add(channel);
          return channel;
        },
        stableAfter: const Duration(seconds: 1),
      );
      addTearDown(socket.dispose);

      socket.connect();
      final first = channels.single;
      // 切断が先に届き、そのあとで握手の完了が届く。
      first.incoming.close();
      async.flushMicrotasks();
      first.readyCompleter.complete();
      async.flushMicrotasks();

      expect(events, [
        ReconnectingSocket.disconnected,
      ], reason: '切れたあとに「つながった」と記録しない');
      expect(first._sink.sent, isEmpty, reason: '切れた接続へ購読を送らない');

      // 張り直しを待っている間に、安定タイマーが試行回数を戻していないこと。
      async.elapse(const Duration(seconds: 5));
      expect(channels, hasLength(2));
      channels.last.incoming.close();
      async.flushMicrotasks();

      expect(delays, [0, 1], reason: '数え直していれば [0, 0] になる');
    });
  });

  test('ふつうの順（握手 → しばらくして切断）では、今までどおり数え直す', () {
    fakeAsync((async) {
      final channels = <_FakeChannel>[];
      final events = <String>[];
      final delays = <int>[];
      final socket = ReconnectingSocket(
        buildUri: () => Uri.parse('ws://example.invalid/'),
        onMessage: (_) {},
        subscribeMessages: () => ['subscribe'],
        delayFor: (attempt) {
          delays.add(attempt);
          return const Duration(seconds: 5);
        },
        onConnectionEvent: events.add,
        channelFactory: (_) {
          final channel = _FakeChannel();
          channels.add(channel);
          return channel;
        },
        stableAfter: const Duration(seconds: 1),
      );
      addTearDown(socket.dispose);

      socket.connect();
      channels.single.readyCompleter.complete();
      async.flushMicrotasks();
      expect(events, [
        ReconnectingSocket.connected,
        ReconnectingSocket.subscribed,
      ]);
      expect(channels.single._sink.sent, ['subscribe']);

      async.elapse(const Duration(seconds: 2));
      channels.single.incoming.close();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));
      channels.last.readyCompleter.complete();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      channels.last.incoming.close();
      async.flushMicrotasks();

      expect(delays, [0, 0], reason: '安定してつながったあとは 0 回目から');
    });
  });
}

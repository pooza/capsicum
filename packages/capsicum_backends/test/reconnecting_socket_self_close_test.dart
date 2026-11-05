import 'dart:async';

import 'package:capsicum_backends/src/reconnecting_socket.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// #1361: こちらから閉じて張り直した（[ReconnectingSocket.closeAndRetry]）ときに、
/// 「相手から閉じられた」（`onClosed`）として記録しない。close code 無しで渡ると
/// サーバーに切られたように見える。
class _FakeSink implements WebSocketSink {
  @override
  void add(Object? data) {}

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChannel implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  final _sink = _FakeSink();

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  Future<void> get ready => Future.value();

  @override
  WebSocketSink get sink => _sink;

  @override
  int? get closeCode => 1001;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late List<_FakeChannel> channels;
  late List<int?> closed;
  late List<String> events;

  ReconnectingSocket build() {
    channels = [];
    closed = [];
    events = [];
    return ReconnectingSocket(
      buildUri: () => Uri.parse('ws://example.invalid/'),
      onMessage: (_) {},
      subscribeMessages: () => const [],
      delayFor: (_) => const Duration(seconds: 1),
      onConnectionEvent: events.add,
      onClosed: (code, _) => closed.add(code),
      channelFactory: (_) {
        final channel = _FakeChannel();
        channels.add(channel);
        return channel;
      },
    );
  }

  test('closeAndRetry は onClosed を呼ばず、張り直しはする', () {
    fakeAsync((async) {
      final socket = build();
      addTearDown(socket.dispose);
      socket.connect();
      async.flushMicrotasks();

      socket.closeAndRetry();
      async.flushMicrotasks();

      expect(closed, isEmpty, reason: 'サーバーに切られたように記録しない');
      expect(events, contains(ReconnectingSocket.disconnected));
      async.elapse(const Duration(seconds: 1));
      expect(channels, hasLength(2), reason: '切れたときと同じ規則で張り直す');
    });
  });

  test('対照: 相手から閉じられたときは、今までどおり close code を渡す', () {
    fakeAsync((async) {
      final socket = build();
      addTearDown(socket.dispose);
      socket.connect();
      async.flushMicrotasks();

      channels.single.incoming.close();
      async.flushMicrotasks();

      expect(closed, [1001]);
    });
  });
}

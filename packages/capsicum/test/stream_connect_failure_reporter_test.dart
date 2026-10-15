import 'dart:io';

import 'package:capsicum/src/service/stream_connect_failure_reporter.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1246: ストリーミング接続の失敗を、アプリ全体で 1 つにまとめて送る。
///
/// ⚠⚠ **以前は購読ごとに間引いていた。**デッキは複数のサーバーへ同時に接続する
/// ので、回線が 1 回切れると接続の本数だけ error が飛んでいた（4 ホスト 7 本
/// なら 7 件）。
void main() {
  (StreamConnectFailureReporter, List<StreamConnectFailureBatch>) make(
    FakeAsync async,
  ) {
    final sent = <StreamConnectFailureBatch>[];
    final reporter = StreamConnectFailureReporter(
      send: sent.add,
      now: () => async.getClock(DateTime.utc(2026, 10, 9)).now(),
    );
    return (reporter, sent);
  }

  void fail(
    StreamConnectFailureReporter reporter,
    String host, {
    String category = 'timeline.stream.connect',
  }) => reporter.report(
    category: category,
    error: StateError('lookup failed'),
    host: host,
  );

  test('⚠⚠ 回線が切れた 1 回は、接続が何本あっても 1 件', () {
    fakeAsync((async) {
      final (reporter, sent) = make(async);

      // 実測の形: 4 ホストに 7 本（3 ホストが 2 本ずつ・1 ホストが 1 本）。
      for (final host in ['a', 'a', 'b', 'b', 'c', 'c', 'd']) {
        fail(reporter, host);
      }
      async.elapse(const Duration(seconds: 6));

      expect(sent, hasLength(1), reason: '以前は 7 件飛んでいた');
      expect(sent.single.connectionCount, 7);
      expect(sent.single.hosts, {'a', 'b', 'c', 'd'});
      expect(
        sent.single.looksLikeNetworkDown,
        isTrue,
        reason: '複数のホストが同時に落ちた ＝ 回線側',
      );
    });
  });

  test('⚠⚠ 1 ホストだけの回は「回線側」と読まない（サーバー側の合図を消さない）', () {
    fakeAsync((async) {
      final (reporter, sent) = make(async);

      // 同じサーバーのタイムラインと通知の 2 本。
      fail(reporter, 'a');
      fail(reporter, 'a', category: 'push.desktop.stream.connect');
      async.elapse(const Duration(seconds: 6));

      expect(sent, hasLength(1), reason: '同じホストの 2 本も 1 件にまとまる');
      expect(sent.single.looksLikeNetworkDown, isFalse);
      expect(sent.single.hosts, {'a'});
      // ⚠ 種別は最初の失敗のもの（既存のイシューへ積まれ続ける）。
      expect(sent.single.category, 'timeline.stream.connect');
    });
  });

  test('まとめる窓の間は送らず、窓が閉じたら送る', () {
    fakeAsync((async) {
      final (reporter, sent) = make(async);

      fail(reporter, 'a');
      async.elapse(const Duration(seconds: 4));
      expect(sent, isEmpty);

      async.elapse(const Duration(seconds: 2));
      expect(sent, hasLength(1));
    });
  });

  test('送ったあとしばらくは送らない（切断中の連発を抑える）', () {
    fakeAsync((async) {
      final (reporter, sent) = make(async);

      fail(reporter, 'a');
      async.elapse(const Duration(seconds: 6));
      // 再接続のたびに失敗が続く。
      for (var i = 0; i < 5; i++) {
        fail(reporter, 'a');
        async.elapse(const Duration(seconds: 8));
      }

      expect(sent, hasLength(1));
    });
  });

  test('静かな時間が過ぎたら、次の回は送る', () {
    fakeAsync((async) {
      final (reporter, sent) = make(async);

      fail(reporter, 'a');
      async.elapse(const Duration(seconds: 6));
      async.elapse(const Duration(minutes: 2));
      fail(reporter, 'b');
      fail(reporter, 'c');
      async.elapse(const Duration(seconds: 6));

      expect(sent, hasLength(2));
      // ⚠ 前の回のホストを持ち越さない。
      expect(sent.last.hosts, {'b', 'c'});
      expect(sent.last.connectionCount, 2);
    });
  });

  test('ホストが分からない接続だけでも送る（回線側とは読まない）', () {
    fakeAsync((async) {
      final (reporter, sent) = make(async);

      reporter.report(category: 'chat.stream.connect', error: StateError('x'));
      async.elapse(const Duration(seconds: 6));

      expect(sent.single.hosts, isEmpty);
      expect(sent.single.looksLikeNetworkDown, isFalse);
      expect(sent.single.connectionCount, 1);
    });
  });

  test('⚠⚠ 送らない時間はホストごと（A が落ちている間の B の失敗を落とさない・#1267）', () {
    fakeAsync((async) {
      final (reporter, sent) = make(async);

      fail(reporter, 'a');
      async.elapse(const Duration(seconds: 6));
      expect(sent, hasLength(1));

      // A の「送らない 60 秒」の最中に、B が落ちる。A の再試行も続いている。
      async.elapse(const Duration(seconds: 10));
      fail(reporter, 'a');
      fail(reporter, 'b');
      async.elapse(const Duration(seconds: 6));

      expect(sent, hasLength(2), reason: '以前は B の失敗が件数にもホストにも入らなかった');
      expect(sent.last.hosts, {'b'}, reason: 'A は送らない時間の中なので入らない');
      expect(sent.last.connectionCount, 1);
      expect(sent.last.looksLikeNetworkDown, isFalse);
    });
  });

  test('⚠⚠ 「回線側」のあとの次のまとめは、1 ホストでも続きとして読む (#1267)', () {
    fakeAsync((async) {
      final (reporter, sent) = make(async);

      for (final host in ['a', 'b', 'c']) {
        fail(reporter, host);
      }
      async.elapse(const Duration(seconds: 6));
      expect(sent.single.looksLikeNetworkDown, isTrue);

      // 長い圏外。再接続の間隔が広がってホストごとにずれ、次の窓には A だけが入る。
      async.elapse(const Duration(seconds: 70));
      fail(reporter, 'a');
      async.elapse(const Duration(seconds: 6));

      expect(sent, hasLength(2));
      expect(sent.last.hosts, {'a'});
      expect(
        sent.last.looksLikeNetworkDown,
        isTrue,
        reason: '同じ圏外の続きを、単一ホストの error として積まない',
      );

      // 続きとして読んだ回が、また次の起点になる。
      async.elapse(const Duration(seconds: 100));
      fail(reporter, 'b');
      async.elapse(const Duration(seconds: 6));
      expect(sent.last.looksLikeNetworkDown, isTrue);
    });
  });

  test('⚠⚠ どこかの接続が成立したら、続きはそこで終わる（1 ホストの障害を畳み続けない）', () {
    fakeAsync((async) {
      final (reporter, sent) = make(async);

      // スリープ明け。全ホストが同時に落ちる。
      for (final host in ['a', 'b', 'c']) {
        fail(reporter, host);
      }
      async.elapse(const Duration(seconds: 6));
      expect(sent.single.looksLikeNetworkDown, isTrue);

      // 回線が戻り、B と C はつながる。A だけ本当に落ちている。
      reporter.noteConnected();

      // A の失敗は 3 分より短い間隔で来続ける。
      for (var i = 0; i < 3; i++) {
        async.elapse(const Duration(seconds: 70));
        fail(reporter, 'a');
        async.elapse(const Duration(seconds: 6));
        expect(sent.last.hosts, {'a'});
        expect(
          sent.last.looksLikeNetworkDown,
          isFalse,
          reason: '回線は生きている。A の障害は error で見えるままにする',
        );
      }
    });
  });

  // #1283: 送らない時間をホストごとにした (#1267) 結果、長い圏外では再接続の
  // 時機がホストごとにずれ、ホストの数だけ「続き」が出ていた。
  test('⚠⚠ 長い圏外の間、送る数がホストの数に比例しない（「回線側」は全体で間引く）', () {
    fakeAsync((async) {
      final (reporter, sent) = make(async);

      for (final host in ['a', 'b', 'c']) {
        fail(reporter, host);
      }
      async.elapse(const Duration(seconds: 6));
      expect(sent, hasLength(1));

      // 60 秒が過ぎ、再接続がホストごとにずれて失敗する（15 秒おき）。
      async.elapse(const Duration(seconds: 60));
      fail(reporter, 'a');
      async.elapse(const Duration(seconds: 15));
      fail(reporter, 'b');
      async.elapse(const Duration(seconds: 15));
      fail(reporter, 'c');
      async.elapse(const Duration(seconds: 6));

      expect(sent, hasLength(2), reason: '以前は a・b・c の 3 件が別々に出て、計 4 件になった');
      expect(sent.last.hosts, {'a'});
      expect(sent.last.looksLikeNetworkDown, isTrue);
    });
  });

  test('⚠ 全体の間引きは、時間が過ぎれば解ける（圏外が続けば、また 1 件送る）', () {
    fakeAsync((async) {
      final (reporter, sent) = make(async);

      fail(reporter, 'a');
      fail(reporter, 'b');
      async.elapse(const Duration(seconds: 6));
      async.elapse(const Duration(seconds: 61));
      fail(reporter, 'b');
      async.elapse(const Duration(seconds: 6));

      expect(sent, hasLength(2));
      expect(sent.last.looksLikeNetworkDown, isTrue);
    });
  });

  test('⚠⚠ 接続が成立したら、全体の間引きも終わる（回線が戻ったあとの障害を黙らせない）', () {
    fakeAsync((async) {
      final (reporter, sent) = make(async);

      fail(reporter, 'a');
      fail(reporter, 'b');
      async.elapse(const Duration(seconds: 6));
      expect(sent.single.looksLikeNetworkDown, isTrue);

      // 回線が戻った直後に、まとめに入っていなかった C だけが落ちる。
      reporter.noteConnected();
      async.elapse(const Duration(seconds: 10));
      fail(reporter, 'c');
      async.elapse(const Duration(seconds: 6));

      expect(sent, hasLength(2), reason: '「回線側」の 60 秒の中でも、C の障害は送る');
      expect(sent.last.hosts, {'c'});
      expect(sent.last.looksLikeNetworkDown, isFalse);
    });
  });

  test('⚠ 間が空けば、続きとは読まない（サーバー側の合図を消さない）', () {
    fakeAsync((async) {
      final (reporter, sent) = make(async);

      fail(reporter, 'a');
      fail(reporter, 'b');
      async.elapse(const Duration(seconds: 6));
      async.elapse(const Duration(minutes: 10));
      fail(reporter, 'a');
      async.elapse(const Duration(seconds: 6));

      expect(sent, hasLength(2));
      expect(sent.last.looksLikeNetworkDown, isFalse);
    });
  });

  /// 報告役が正しくても、購読の側が自前で Sentry へ送っていれば元へ戻る。
  group('接続の失敗を、購読の側が直接 Sentry へ送っていない', () {
    const sites = {
      'lib/src/provider/timeline_provider.dart': 'timeline.stream.connect',
      'lib/src/provider/chat_provider.dart': 'chat.stream.connect',
      'lib/src/service/desktop_notification_dispatcher.dart':
          'push.desktop.stream.connect',
    };

    for (final MapEntry(key: path, value: category) in sites.entries) {
      test(path, () {
        final src = maskComments(File(path).readAsStringSync());
        expect(
          src,
          contains('streamConnectFailureReporter.report('),
          reason: '報告役を通していない',
        );
        expect(src, contains("category: '$category'"));
        expect(
          src,
          isNot(contains("scope.setTag('$category', 'failed')")),
          reason: '購読ごとに直接送っている（接続の本数だけ飛ぶ形へ戻った）',
        );
      });
    }
  });
}

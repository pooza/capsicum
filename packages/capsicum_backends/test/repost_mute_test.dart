import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1245: 特定の相手のブースト / リノートだけを TL に出さない。
///
/// 経路が SNS で違う —— Mastodon はフォローの属性（`reblogs`）、Misskey は
/// フォローと独立した `renote-mute/*`。
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.routes, {this.statuses = const {}});

  final Map<String, Object> routes;

  /// 経路ごとの HTTP ステータス（無ければ 200）。
  final Map<String, int> statuses;
  final List<(String path, Object? data)> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add((options.path, options.data));
    final entry = routes.entries.firstWhere(
      (e) => options.path.contains(e.key),
      orElse: () => throw StateError('no route for ${options.path}'),
    );
    return ResponseBody.fromString(
      jsonEncode(entry.value),
      statuses[entry.key] ?? 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('Mastodon', () {
    Future<(MastodonAdapter, _RecordingAdapter)> setUpAdapter(
      Map<String, Object> routes,
    ) async {
      final adapter = await MastodonAdapter.create('mstdn.example');
      final http = _RecordingAdapter(routes);
      adapter.client.dio.httpClientAdapter = http;
      return (adapter, http);
    }

    test('フォロー中の相手にしか設定できない', () async {
      final (adapter, _) = await setUpAdapter({});
      expect(adapter.repostMuteRequiresFollow, isTrue);
    });

    test('showing_reblogs を読む', () async {
      final (adapter, _) = await setUpAdapter({
        'relationships': [
          {'id': '1', 'following': true, 'showing_reblogs': false},
        ],
      });
      expect((await adapter.getRelationship('1')).showingReposts, isFalse);
    });

    test('⚠ 返ってこなければ「出している」と読む（逆向きに倒れる項目にしない）', () async {
      final (adapter, _) = await setUpAdapter({
        'relationships': [
          {'id': '1', 'following': true},
        ],
      });
      expect((await adapter.getRelationship('1')).showingReposts, isTrue);
    });

    test('⚠⚠ follow へ reblogs だけを送る（notify / languages は送らない）', () async {
      // サーバーは送られたキーだけを書き換える。既定値を一緒に送ると、相手に
      // 設定していた「投稿の通知」と言語の絞り込みが消える。
      final (adapter, http) = await setUpAdapter({
        'follow': <String, Object>{},
      });

      await adapter.setShowReposts('1', show: false);
      expect(http.calls.single.$1, '/api/v1/accounts/1/follow');
      expect(http.calls.single.$2, {'reblogs': false});

      await adapter.setShowReposts('1', show: true);
      expect(http.calls.last.$2, {'reblogs': true});
    });

    test('⚠ ふつうのフォローは今までどおり何も送らない', () async {
      final (adapter, http) = await setUpAdapter({
        'follow': <String, Object>{},
      });

      await adapter.followUser('1');
      expect(http.calls.single.$2, isNull);
    });
  });

  group('Misskey', () {
    Future<(MisskeyAdapter, _RecordingAdapter)> setUpAdapter(
      Map<String, Object> routes,
    ) async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _RecordingAdapter(routes);
      adapter.client.dio.httpClientAdapter = http;
      return (adapter, http);
    }

    test('フォローしていない相手にも設定できる', () async {
      final (adapter, _) = await setUpAdapter({});
      expect(adapter.repostMuteRequiresFollow, isFalse);
    });

    test('isRenoteMuted の裏返しを読む', () async {
      final (adapter, _) = await setUpAdapter({
        'users/relation': {'id': 'u1', 'isRenoteMuted': true},
      });
      expect((await adapter.getRelationship('u1')).showingReposts, isFalse);

      final (adapter2, _) = await setUpAdapter({
        'users/relation': {'id': 'u1', 'isRenoteMuted': false},
      });
      expect((await adapter2.getRelationship('u1')).showingReposts, isTrue);
    });

    test('出さないなら renote-mute/create、出すなら delete', () async {
      final (adapter, http) = await setUpAdapter({
        'renote-mute': <String, Object>{},
      });

      await adapter.setShowReposts('u1', show: false);
      expect(http.calls.single.$1, contains('renote-mute/create'));
      expect((http.calls.single.$2! as Map)['userId'], 'u1');

      await adapter.setShowReposts('u1', show: true);
      expect(http.calls.last.$1, contains('renote-mute/delete'));
    });

    test('⚠ 既にその状態（ALREADY_MUTING / NOT_MUTING）は成功と同じに倒す', () async {
      // 別の端末で切り替えたあとに押した回。失敗にすると、メニューの文面が
      // 古いまま残り、押すたびに失敗し続ける。
      Future<void> run(String route, String code, {required bool show}) async {
        final adapter = await MisskeyAdapter.create('misskey.example');
        adapter.client.dio.httpClientAdapter = _RecordingAdapter(
          {
            route: {
              'error': {'message': 'x', 'code': code, 'id': 'x'},
            },
          },
          statuses: {route: 400},
        );
        await adapter.setShowReposts('u1', show: show);
      }

      await run('renote-mute/create', 'ALREADY_MUTING', show: false);
      await run('renote-mute/delete', 'NOT_MUTING', show: true);
    });

    test('⚠ それ以外の失敗は握らない', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _RecordingAdapter(
        {
          'renote-mute/create': {
            'error': {'message': 'x', 'code': 'NO_SUCH_USER', 'id': 'x'},
          },
        },
        statuses: {'renote-mute/create': 400},
      );
      await expectLater(
        adapter.setShowReposts('u1', show: false),
        throwsA(isA<DioException>()),
      );
    });
  });
}

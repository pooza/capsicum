import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_backends/src/misskey/extensions.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1211: リストの設定と、フォローごとの「返信を流すか」。
///
/// ここで固定するのは**送信するリクエストの形**と**現在値の読み方**。どちらも
/// 部分更新なので、余計な項目を送ると変えるつもりの無い設定を上書きする。
class _Recorder implements HttpClientAdapter {
  _Recorder(this.respond);

  final Object Function(RequestOptions options) respond;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(respond(options)),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _body(RequestOptions options) =>
    options.data as Map<String, dynamic>;

void main() {
  group('Mastodon のリスト', () {
    late MastodonAdapter adapter;
    late _Recorder http;

    setUp(() async {
      adapter = await MastodonAdapter.create('example.com');
      http = _Recorder(
        (options) => options.method == 'GET'
            ? [
                {
                  'id': '1',
                  'title': '家族',
                  'replies_policy': 'followed',
                  'exclusive': true,
                },
                // 4.2 より前のサーバーは exclusive を返さない。
                {'id': '2', 'title': '古い形'},
              ]
            : {
                'id': '1',
                'title': '家族',
                'replies_policy': 'none',
                'exclusive': false,
              },
      );
      adapter.client.dio.httpClientAdapter = http;
    });

    test('⚠⚠ 現在値を読む（以前は title しか読んでいなかった）', () async {
      final lists = await adapter.getLists();

      expect(lists.first.repliesPolicy, ListRepliesPolicy.followed);
      expect(lists.first.exclusive, isTrue);
      expect(lists.first.isPublic, isNull, reason: 'Mastodon には無い項目');
      expect(lists.first.hasSettings, isTrue);
    });

    test('⚠ サーバーが返さない項目は null（画面はその項目を出さない）', () async {
      final lists = await adapter.getLists();

      expect(lists.last.repliesPolicy, isNull);
      expect(lists.last.exclusive, isNull);
      expect(lists.last.hasSettings, isFalse);
    });

    test('⚠⚠ 渡した項目だけを送る（title を送らない）', () async {
      final updated = await adapter.updateListSettings('1', exclusive: false);

      final request = http.requests.single;
      expect(request.method, 'PUT');
      expect(request.path, '/api/v1/lists/1');
      expect(_body(request), {'exclusive': false});
      expect(updated.exclusive, isFalse);
    });

    test('返信の範囲は API の語彙で送る', () async {
      await adapter.updateListSettings(
        '1',
        repliesPolicy: ListRepliesPolicy.none,
      );

      expect(_body(http.requests.single), {'replies_policy': 'none'});
    });

    test('⚠ Mastodon に無い項目（公開）は、渡されても送らない', () async {
      await adapter.updateListSettings('1', exclusive: true, isPublic: true);

      expect(_body(http.requests.single), {'exclusive': true});
    });
  });

  group('Misskey のリスト', () {
    late MisskeyAdapter adapter;
    late _Recorder http;

    setUp(() async {
      adapter = await MisskeyAdapter.create('misskey.example');
      http = _Recorder(
        (options) => options.path.contains('lists/list')
            ? [
                {'id': 'l1', 'name': '家族', 'isPublic': false},
              ]
            : {'id': 'l1', 'name': '家族', 'isPublic': true},
      );
      adapter.client.dio.httpClientAdapter = http;
    });

    test('現在値（公開かどうか）を読む', () async {
      final list = (await adapter.getLists()).single;

      expect(list.isPublic, isFalse);
      expect(list.repliesPolicy, isNull, reason: 'Misskey には無い項目');
      expect(list.exclusive, isNull);
      expect(list.hasSettings, isTrue);
    });

    test('⚠⚠ 公開だけを送る（name を送らない）', () async {
      final updated = await adapter.updateListSettings('l1', isPublic: true);

      final request = http.requests.single;
      expect(request.path, contains('users/lists/update'));
      final body = _body(request);
      expect(body['listId'], 'l1');
      expect(body['isPublic'], isTrue);
      expect(body.containsKey('name'), isFalse);
      expect(updated.isPublic, isTrue);
    });

    test('⚠ Misskey に無い項目だけを渡されたら、更新を送らない', () async {
      await adapter.updateListSettings(
        'l1',
        repliesPolicy: ListRepliesPolicy.none,
        exclusive: true,
      );

      expect(
        http.requests.where((r) => r.path.contains('lists/update')),
        isEmpty,
        reason: '空の更新を送らない',
      );
    });
  });

  group('返信の範囲の語彙', () {
    test('API の値と往復する', () {
      for (final policy in ListRepliesPolicy.values) {
        expect(ListRepliesPolicy.fromApi(policy.apiValue), policy);
      }
    });

    test('⚠ 知らない値・null は null（設定を出さない）', () {
      expect(ListRepliesPolicy.fromApi('mutuals'), isNull);
      expect(ListRepliesPolicy.fromApi(null), isNull);
    });
  });

  group('Misskey のフォローごとの「返信を流すか」', () {
    test('関係の応答の、フォローの記録から読む', () {
      expect(
        misskeyFollowWithReplies({
          'isFollowing': true,
          'following': {'id': 'f1', 'withReplies': true},
        }),
        isTrue,
      );
      expect(
        misskeyFollowWithReplies({
          'isFollowing': true,
          'following': {'id': 'f1', 'withReplies': false},
        }),
        isFalse,
      );
    });

    // false に倒すと、押すと逆向きに倒れる項目になる。
    test('⚠⚠ 読めないときは null（フォローしていない・項目が無い）', () {
      expect(
        misskeyFollowWithReplies({'isFollowing': false, 'following': null}),
        isNull,
      );
      expect(misskeyFollowWithReplies({'isFollowing': true}), isNull);
      expect(
        misskeyFollowWithReplies({
          'isFollowing': true,
          'following': {'id': 'f1'},
        }),
        isNull,
      );
    });

    test('関係を引くと、その値が載る', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _Recorder(
        (_) => {
          'id': 'u1',
          'isFollowing': true,
          'following': {'id': 'f1', 'withReplies': true},
        },
      );

      final relationship = await adapter.getRelationship('u1');

      expect(relationship.following, isTrue);
      expect(relationship.showingReplies, isTrue);
    });

    test('⚠ withReplies だけを送る（notify を送らない）', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _Recorder((_) => <String, dynamic>{});
      adapter.client.dio.httpClientAdapter = http;

      await (adapter as FollowRepliesSupport).setShowReplies('u1', show: false);

      final request = http.requests.single;
      expect(request.path, contains('following/update'));
      final body = _body(request);
      expect(body['userId'], 'u1');
      expect(body['withReplies'], isFalse);
      expect(body.containsKey('notify'), isFalse);
    });
  });
}

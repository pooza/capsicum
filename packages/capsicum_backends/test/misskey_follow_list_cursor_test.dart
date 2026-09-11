import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Misskey のフォロー / フォロワー一覧の次のカーソル（v1.64 のリリース前
/// レビュー）。
///
/// サーバーは**関係レコード（following）の id** でページングする
/// （`users/followers.ts` の `makePaginationQuery(followingsRepository…)`）。
/// 以前は相手の User id を返していたので、2 ページ目が「最後に表示した人の
/// アカウント作成時刻より前のフォロー」から始まり、その間が抜けていた。
class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter(this.body);

  final Object body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _user(String id) => {'id': id, 'username': 'u$id'};

void main() {
  // 関係レコードの id（フォローした時刻）と相手の User id（アカウント作成時刻）
  // はまったく別の値。
  final records = [
    {'id': 'rel-2', 'follower': _user('user-a'), 'followee': _user('user-b')},
    {'id': 'rel-1', 'follower': _user('user-c'), 'followee': _user('user-d')},
  ];

  test('フォロワー一覧の次のカーソルは関係レコードの id', () async {
    final adapter = await MisskeyAdapter.create('misskey.example');
    adapter.client.dio.httpClientAdapter = _FixedAdapter(records);

    final page = await adapter.getFollowers('me');
    expect(page.users.map((u) => u.id), ['user-a', 'user-c']);
    expect(page.nextCursor, 'rel-1', reason: '相手の User id（user-c）ではない');
  });

  test('フォロー一覧の次のカーソルも関係レコードの id', () async {
    final adapter = await MisskeyAdapter.create('misskey.example');
    adapter.client.dio.httpClientAdapter = _FixedAdapter(records);

    final page = await adapter.getFollowing('me');
    expect(page.users.map((u) => u.id), ['user-b', 'user-d']);
    expect(page.nextCursor, 'rel-1', reason: '相手の User id（user-d）ではない');
  });

  test('空なら打ち止め', () async {
    final adapter = await MisskeyAdapter.create('misskey.example');
    adapter.client.dio.httpClientAdapter = _FixedAdapter(<Object>[]);
    expect((await adapter.getFollowers('me')).nextCursor, isNull);
  });
}

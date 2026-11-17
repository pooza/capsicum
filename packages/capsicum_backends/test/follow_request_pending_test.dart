import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1400: フォローの「リクエスト中」を読み、取り下げる。
///
/// ⚠ 承認制の相手だけではない。Mastodon は外部のサーバーのアカウントを
/// フォローすると、Accept が届くまで `following: false` / `requested: true` を
/// 返す（2026-11-18 に美食丼 → pawoo で実際に起きた）。
class _Recorder implements HttpClientAdapter {
  _Recorder(this.response);

  final Object response;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
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
    Future<(MastodonAdapter, _Recorder)> adapterWith(Object response) async {
      final adapter = await MastodonAdapter.create('mastodon.example');
      final http = _Recorder(response);
      adapter.client.dio.httpClientAdapter = http;
      return (adapter, http);
    }

    test('relationship の requested を読む', () async {
      final (adapter, _) = await adapterWith([
        {'id': '9', 'following': false, 'requested': true},
      ]);
      final rel = await adapter.getRelationship('9');

      expect(rel.following, isFalse);
      expect(rel.requested, isTrue);
    });

    test('requested が無ければ false', () async {
      final (adapter, _) = await adapterWith([
        {'id': '9', 'following': true},
      ]);

      expect((await adapter.getRelationship('9')).requested, isFalse);
    });

    test('取り下げは unfollow を送る（Mastodon は兼ねる）', () async {
      final (adapter, http) = await adapterWith({'id': '9'});
      await adapter.cancelFollowRequest('9');

      expect(http.requests.single.method, 'POST');
      expect(http.requests.single.path, '/api/v1/accounts/9/unfollow');
    });
  });

  group('Misskey', () {
    Future<(MisskeyAdapter, _Recorder)> adapterWith(Object response) async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _Recorder(response);
      adapter.client.dio.httpClientAdapter = http;
      return (adapter, http);
    }

    test('hasPendingFollowRequestFromYou を読む', () async {
      final (adapter, _) = await adapterWith({
        'id': 'u',
        'isFollowing': false,
        'hasPendingFollowRequestFromYou': true,
      });
      final rel = await adapter.getRelationship('u');

      expect(rel.following, isFalse);
      expect(rel.requested, isTrue);
    });

    test('⚠ 取り下げは following/requests/cancel（following/delete ではない）', () async {
      final (adapter, http) = await adapterWith(<String, dynamic>{});
      await adapter.cancelFollowRequest('u');

      final request = http.requests.single;
      expect(request.path, '/api/following/requests/cancel');
      expect((request.data as Map)['userId'], 'u');
    });
  });
}

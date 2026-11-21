import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1401: アカウントを削除したら、サーバー側のトークンを取り消す。
///
/// 取り消さないと、サーバーの「連携アプリ」に capsicum の承認が残り続け、
/// ログインし直すたびに溜まっていく。
class _Recorder implements HttpClientAdapter {
  _Recorder({this.status = 200});

  final int status;
  final requests = <({String path, Map<String, dynamic> body})>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var body = <String, dynamic>{};
    if (requestStream != null) {
      final bytes = (await requestStream.toList()).expand((c) => c).toList();
      if (bytes.isNotEmpty) {
        body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      }
    }
    requests.add((path: options.path, body: body));
    return ResponseBody.fromString(
      status == 204 ? '' : jsonEncode(<String, dynamic>{}),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('Mastodon 系（/oauth/revoke）', () {
    test('client_id / client_secret / token を送って取り消す', () async {
      final adapter = await MastodonAdapter.create('mstdn.example');
      final http = _Recorder();
      adapter.client.dio.httpClientAdapter = http;

      await adapter.revokeOwnToken(
        const UserSecret(accessToken: 'tok-a'),
        clientSecret: const ClientSecretData(
          clientId: 'cid',
          clientSecret: 'csecret',
        ),
      );

      expect(http.requests, hasLength(1));
      expect(http.requests.single.path, '/oauth/revoke');
      expect(http.requests.single.body, {
        'client_id': 'cid',
        'client_secret': 'csecret',
        'token': 'tok-a',
      });
    });

    test('⚠ クライアントの資格情報が無ければ何も送らない（取り消せない）', () async {
      final adapter = await MastodonAdapter.create('mstdn.example');
      final http = _Recorder();
      adapter.client.dio.httpClientAdapter = http;

      await adapter.revokeOwnToken(const UserSecret(accessToken: 'tok-a'));

      expect(http.requests, isEmpty);
    });

    test('失敗は投げる（握りつぶすかは呼ぶ側が決める）', () async {
      final adapter = await MastodonAdapter.create('mstdn.example');
      adapter.client.dio.httpClientAdapter = _Recorder(status: 500);

      await expectLater(
        adapter.revokeOwnToken(
          const UserSecret(accessToken: 'tok-a'),
          clientSecret: const ClientSecretData(
            clientId: 'cid',
            clientSecret: 'csecret',
          ),
        ),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('Misskey（/api/i/revoke-token・2026.9.0 から）', () {
    test('自分のトークンを i と token の両方に入れて取り消す', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _Recorder(status: 204);
      adapter.client.dio.httpClientAdapter = http;

      await adapter.revokeOwnToken(const UserSecret(accessToken: 'tok-m'));

      expect(http.requests, hasLength(1));
      expect(http.requests.single.path, '/api/i/revoke-token');
      expect(http.requests.single.body, {'i': 'tok-m', 'token': 'tok-m'});
    });

    test('古いサーバー（口が無い）では投げる', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.dio.httpClientAdapter = _Recorder(status: 400);

      await expectLater(
        adapter.revokeOwnToken(const UserSecret(accessToken: 'tok-m')),
        throwsA(isA<DioException>()),
      );
    });
  });

  test('両方のアダプターが TokenRevokeSupport を持つ', () async {
    expect(
      await MastodonAdapter.create('mstdn.example'),
      isA<TokenRevokeSupport>(),
    );
    expect(
      await MisskeyAdapter.create('misskey.example'),
      isA<TokenRevokeSupport>(),
    );
  });
}

import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// path ごとに応答を返し、`/oauth/token` のリクエストボディを記録する adapter。
/// #790 の PKCE (code_verifier) / state 照合の挙動を検証する。
class _RecordingAdapter implements HttpClientAdapter {
  Map<String, dynamic>? tokenBody;
  int tokenCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == '/oauth/token') {
      tokenCalls++;
      if (requestStream != null) {
        final chunks = await requestStream.toList();
        final bytes = chunks.expand((c) => c).toList();
        tokenBody = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      }
      return ResponseBody.fromString(
        jsonEncode({'access_token': 'tok-xyz'}),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    if (options.path == '/api/v1/accounts/verify_credentials') {
      return ResponseBody.fromString(
        jsonEncode(_account),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    throw StateError('unexpected path ${options.path}');
  }

  @override
  void close({bool force = false}) {}
}

const _account = <String, dynamic>{
  'id': '1',
  'username': 'capsicum',
  'acct': 'capsicum@example.com',
  'display_name': 'capsicum',
  'note': '',
  'avatar': '',
  'header': '',
  'followers_count': 0,
  'following_count': 0,
  'statuses_count': 0,
  'fields': <Map<String, dynamic>>[],
};

ApplicationInfo _appInfo() => ApplicationInfo(
  name: 'capsicum',
  redirectUri: Uri.parse('http://localhost:7099/oauth/callback'),
  scopes: const ['read', 'write', 'follow', 'push'],
);

Future<MastodonAdapter> _adapter(_RecordingAdapter http) async {
  final adapter = await MastodonAdapter.create('mastodon.example');
  // createApplication (POST /api/v1/apps) をスキップさせ startLogin をネットワーク
  // 非依存にする。
  adapter.setCachedClientCredentials(
    ClientSecretData(clientId: 'cid', clientSecret: 'csecret'),
  );
  adapter.client.dio.httpClientAdapter = http;
  return adapter;
}

void main() {
  group('MastodonAdapter.startLogin PKCE + state (#790)', () {
    test(
      'authorize URL に state / code_challenge(S256) を載せ extra に verifier を退避',
      () async {
        final adapter = await _adapter(_RecordingAdapter());
        final result = await adapter.startLogin(_appInfo());

        expect(result, isA<LoginNeedsOAuth>());
        final oauth = result as LoginNeedsOAuth;
        final q = oauth.authorizationUrl.queryParameters;

        final state = oauth.extra['state'];
        final verifier = oauth.extra['code_verifier'];
        expect(state, isNotNull);
        expect(verifier, isNotNull);

        // URL の state と extra の state は一致する。
        expect(q['state'], state);
        expect(q['code_challenge_method'], 'S256');

        // challenge は base64url(sha256(verifier)) の padding 除去。
        final expectedChallenge = base64Url
            .encode(sha256.convert(ascii.encode(verifier!)).bytes)
            .replaceAll('=', '');
        expect(q['code_challenge'], expectedChallenge);

        // verifier（秘密）は認可リクエストに載らない。
        expect(oauth.authorizationUrl.toString(), isNot(contains(verifier)));
      },
    );
  });

  group('MastodonAdapter.completeLogin state 照合 (#790)', () {
    test('state 一致で token 交換に code_verifier を送り成功する', () async {
      final http = _RecordingAdapter();
      final adapter = await _adapter(http);
      final start = await adapter.startLogin(_appInfo()) as LoginNeedsOAuth;
      final state = start.extra['state']!;
      final verifier = start.extra['code_verifier']!;

      final result = await adapter.completeLogin(
        Uri.parse(
          'http://localhost:7099/oauth/callback?code=authcode&state=$state',
        ),
        start.extra,
      );

      expect(result, isA<LoginSuccess>());
      expect(http.tokenBody?['code'], 'authcode');
      expect(http.tokenBody?['code_verifier'], verifier);
    });

    test('state 不一致は token 交換せず LoginFailure を返す', () async {
      final http = _RecordingAdapter();
      final adapter = await _adapter(http);
      final start = await adapter.startLogin(_appInfo()) as LoginNeedsOAuth;

      final result = await adapter.completeLogin(
        Uri.parse(
          'http://localhost:7099/oauth/callback?code=authcode&state=WRONG',
        ),
        start.extra,
      );

      expect(result, isA<LoginFailure>());
      expect(http.tokenCalls, 0);
    });
  });
}

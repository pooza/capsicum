import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1372: メール未確認・承認待ちでログインを止めたら、発行したばかりの
/// トークンを revoke する。凍結・ログイン停止は
/// 手元のセッションと同じトークンが返っていることがあるので revoke しない。
/// 4.7 以前の 403 も、本文で承認待ち・メール未確認と分かれば revoke する。
class _LoginAdapter implements HttpClientAdapter {
  _LoginAdapter({required this.verifyStatus, required this.verifyBody});

  final int verifyStatus;
  final Object verifyBody;
  Map<String, dynamic>? revokeBody;
  bool failRevoke = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    ResponseBody json(Object body, int status) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
    switch (options.path) {
      case '/oauth/token':
        return json({'access_token': 'tok-new'}, 200);
      case '/api/v1/accounts/verify_credentials':
        return json(verifyBody, verifyStatus);
      case '/oauth/revoke':
        if (requestStream != null) {
          final bytes = (await requestStream.toList()).expand((c) => c);
          revokeBody =
              jsonDecode(utf8.decode(bytes.toList())) as Map<String, dynamic>;
        }
        return json(<String, dynamic>{}, failRevoke ? 500 : 200);
    }
    throw StateError('unexpected path ${options.path}');
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _account(Map<String, dynamic> state) => {
  'id': '1',
  'username': 'newbie',
  'acct': 'newbie',
  'display_name': '',
  'note': '',
  'avatar': '',
  'header': '',
  'followers_count': 0,
  'following_count': 0,
  'statuses_count': 0,
  'fields': <Object>[],
  'state': state,
};

Map<String, dynamic> _nonFunctional(String code) => {
  'functional': false,
  'error_code': code,
  'error': '説明',
};

Future<LoginResult> _login(_LoginAdapter http) async {
  final adapter = await MastodonAdapter.create('mstdn.example');
  adapter.setCachedClientCredentials(
    ClientSecretData(clientId: 'cid', clientSecret: 'csecret'),
  );
  adapter.client.dio.httpClientAdapter = http;
  final start =
      await adapter.startLogin(
            ApplicationInfo(
              name: 'capsicum',
              redirectUri: Uri.parse('http://localhost:7099/oauth/callback'),
              scopes: const ['read'],
            ),
          )
          as LoginNeedsOAuth;
  return adapter.completeLogin(
    Uri.parse(
      'http://localhost:7099/oauth/callback?code=c&state=${start.extra['state']}',
    ),
    start.extra,
  );
}

void main() {
  for (final code in ['pending_confirmation', 'pending_approval']) {
    test('$code なら revoke して、理由つきで失敗を返す', () async {
      final http = _LoginAdapter(
        verifyStatus: 200,
        verifyBody: _account(_nonFunctional(code)),
      );
      final result = await _login(http);

      expect(
        result,
        isA<LoginFailure>().having(
          (f) => f.error,
          'error',
          isA<MastodonAccountNotFunctional>().having(
            (e) => e.errorCode,
            'errorCode',
            code,
          ),
        ),
      );
      expect(http.revokeBody, {
        'client_id': 'cid',
        'client_secret': 'csecret',
        'token': 'tok-new',
      });
    });
  }

  test('revoke が失敗しても、止めた理由のほうを返す', () async {
    final http = _LoginAdapter(
      verifyStatus: 200,
      verifyBody: _account(_nonFunctional('pending_approval')),
    )..failRevoke = true;
    final result = await _login(http);

    expect(
      result,
      isA<LoginFailure>().having(
        (f) => f.error,
        'error',
        isA<MastodonAccountNotFunctional>(),
      ),
    );
  });

  test('⚠⚠ 凍結（account_suspended）は revoke しない', () async {
    final http = _LoginAdapter(
      verifyStatus: 200,
      verifyBody: _account(_nonFunctional('account_suspended')),
    );
    final result = await _login(http);

    expect(result, isA<LoginFailure>());
    expect(http.revokeBody, isNull);
  });

  test('⚠⚠ 4.7 以前の 403 の login_disabled は revoke しない', () async {
    final http = _LoginAdapter(
      verifyStatus: 403,
      verifyBody: {'error': 'Your login is currently disabled'},
    );
    final result = await _login(http);

    expect(result, isA<LoginFailure>());
    expect(http.revokeBody, isNull);
  });

  test('4.7 以前の 403 でも、承認待ちと分かれば revoke する', () async {
    final http = _LoginAdapter(
      verifyStatus: 403,
      verifyBody: {'error': 'Your login is currently pending approval'},
    );
    final result = await _login(http);

    expect(result, isA<LoginFailure>());
    expect(http.revokeBody?['token'], 'tok-new');
  });

  test('使えるアカウントなら revoke しない', () async {
    final http = _LoginAdapter(
      verifyStatus: 200,
      verifyBody: _account({'functional': true}),
    );
    final result = await _login(http);

    expect(result, isA<LoginSuccess>());
    expect(http.revokeBody, isNull);
  });
}

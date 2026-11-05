import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1320: ログインはできたが使えない状態のアカウント（承認待ち・メール未確認）を
/// 見分ける。5.0 は `allow_nonfunctional=true` の `state`、4.7 以前は 403 の本文。
class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter(this.status, this.body);

  final int status;
  final Object body;
  RequestOptions? last;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    last = options;
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _account({Map<String, dynamic>? state}) => {
  'id': '1',
  'username': 'newbie',
  'acct': 'newbie',
  'display_name': '',
  'locked': false,
  'bot': false,
  'created_at': '2026-11-05T00:00:00.000Z',
  'note': '',
  'url': 'https://mstdn.example/@newbie',
  'avatar': 'https://mstdn.example/avatars/original/missing.png',
  'avatar_static': 'https://mstdn.example/avatars/original/missing.png',
  'header': 'https://mstdn.example/headers/original/missing.png',
  'header_static': 'https://mstdn.example/headers/original/missing.png',
  'followers_count': 0,
  'following_count': 0,
  'statuses_count': 0,
  'emojis': <Object>[],
  'fields': <Object>[],
  'state': ?state,
};

MastodonClient _client(_FixedAdapter http) {
  final client = MastodonClient('mstdn.example');
  client.dio.httpClientAdapter = http;
  return client;
}

void main() {
  group('5.0: state で見分ける', () {
    test('承認待ちなら pending_approval とサーバーの説明を持って投げる', () async {
      final http = _FixedAdapter(
        200,
        _account(
          state: {
            'functional': false,
            'confirmed': true,
            'approved': false,
            'error_code': 'pending_approval',
            'error': 'アカウントは承認待ちです',
          },
        ),
      );
      await expectLater(
        _client(http).verifyCredentials(allowNonfunctional: true),
        throwsA(
          isA<MastodonAccountNotFunctional>()
              .having((e) => e.errorCode, 'errorCode', 'pending_approval')
              .having((e) => e.serverMessage, 'serverMessage', 'アカウントは承認待ちです'),
        ),
      );
      expect(http.last!.queryParameters['allow_nonfunctional'], 'true');
    });

    test('使える状態なら、そのままアカウントを返す', () async {
      final http = _FixedAdapter(
        200,
        _account(
          state: {
            'functional': true,
            'confirmed': true,
            'approved': true,
            'error_code': null,
            'error': null,
          },
        ),
      );
      final account = await _client(
        http,
      ).verifyCredentials(allowNonfunctional: true);
      expect(account.username, 'newbie');
    });

    test('⚠ 引っ越し済み（functional は false・error_code は null）は、そのまま返す', () async {
      // 5.0 の `functional?` は moved_to_account_id を含むが、
      // `nonfunctional_reason` は nil で、require_user! も通す。
      final http = _FixedAdapter(
        200,
        _account(
          state: {
            'functional': false,
            'confirmed': true,
            'approved': true,
            'error_code': null,
            'error': null,
          },
        ),
      );
      final account = await _client(
        http,
      ).verifyCredentials(allowNonfunctional: true);
      expect(account.username, 'newbie');
    });

    test('state が無い（4.7 以前の 200）なら、そのまま返す', () async {
      final http = _FixedAdapter(200, _account());
      final account = await _client(
        http,
      ).verifyCredentials(allowNonfunctional: true);
      expect(account.username, 'newbie');
    });
  });

  group('4.7 以前: 403 の本文で見分ける', () {
    for (final (message, code) in [
      (
        'Your login is missing a confirmed e-mail address',
        'pending_confirmation',
      ),
      ('Your login is currently pending approval', 'pending_approval'),
      ('Your login is currently disabled', 'login_disabled'),
    ]) {
      test('「$message」は $code', () async {
        final http = _FixedAdapter(403, {'error': message});
        await expectLater(
          _client(http).verifyCredentials(allowNonfunctional: true),
          throwsA(
            isA<MastodonAccountNotFunctional>()
                .having((e) => e.errorCode, 'errorCode', code)
                .having((e) => e.serverMessage, 'serverMessage', isNull),
          ),
        );
      });
    }

    test('知らない 403 は DioException のまま', () async {
      final http = _FixedAdapter(403, {
        'error': 'This action is outside the authorized scopes',
      });
      await expectLater(
        _client(http).verifyCredentials(allowNonfunctional: true),
        throwsA(isA<DioException>()),
      );
    });
  });

  test('⚠⚠ ログイン以外（allowNonfunctional なし）では詰め替えない', () async {
    // セッションの復元は 403 を DioException のまま受けて「認証が失効した」と
    // 読む（classifyRestoreFailure）。ここで型が変わると分類が変わる。
    final http = _FixedAdapter(403, {
      'error': 'Your login is currently pending approval',
    });
    await expectLater(
      _client(http).verifyCredentials(),
      throwsA(isA<DioException>()),
    );
    expect(
      http.last!.queryParameters.containsKey('allow_nonfunctional'),
      false,
    );
  });
}

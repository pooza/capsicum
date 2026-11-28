// #1401: アカウントの削除で、サーバー側のトークンを取り消す。
import 'dart:io';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'support/dart_source.dart';

class _PlainAdapter extends Mock implements DecentralizedBackendAdapter {}

class _MastodonAdapter extends Mock implements MastodonAdapter {}

class _RevokingAdapter extends Mock
    implements DecentralizedBackendAdapter, TokenRevokeSupport {}

Account _account(DecentralizedBackendAdapter adapter) => Account(
  key: const AccountKey(
    type: BackendType.mastodon,
    host: 'mstdn.example',
    username: 'alice',
  ),
  adapter: adapter,
  user: const User(id: '1', username: 'alice'),
  userSecret: const UserSecret(accessToken: 'tok-a'),
  clientSecret: const ClientSecretData(clientId: 'cid', clientSecret: 'cs'),
);

void main() {
  setUpAll(() {
    registerFallbackValue(const UserSecret(accessToken: ''));
  });

  group('revokeTokenOnLogout', () {
    test('トークンとクライアントの資格情報を渡して取り消す', () async {
      final adapter = _RevokingAdapter();
      when(
        () => adapter.revokeOwnToken(
          any(),
          clientSecret: any(named: 'clientSecret'),
        ),
      ).thenAnswer((_) async {});

      await AccountManagerNotifier.revokeTokenOnLogout(_account(adapter));

      final captured = verify(
        () => adapter.revokeOwnToken(
          captureAny(),
          clientSecret: captureAny(named: 'clientSecret'),
        ),
      ).captured;
      expect((captured[0] as UserSecret).accessToken, 'tok-a');
      expect((captured[1] as ClientSecretData).clientId, 'cid');
    });

    test('⚠ 失敗しても投げない（端末側の削除はもう終わっている）', () async {
      final adapter = _RevokingAdapter();
      when(
        () => adapter.revokeOwnToken(
          any(),
          clientSecret: any(named: 'clientSecret'),
        ),
      ).thenThrow(StateError('offline'));

      await expectLater(
        AccountManagerNotifier.revokeTokenOnLogout(_account(adapter)),
        completes,
      );
    });

    // ⚠⚠ Mastodon は同じアプリ・同じ利用者・同じスコープなら同じトークンを返す
    // （Doorkeeper の `reuse_access_token`）。消してすぐ入れ直した回に取り消すと、
    // 入れ直したほうが 401 になる（リリース前レビュー 2026-11-22）。
    test('⚠ 同じアカウントが入り直していたら取り消さない', () async {
      final adapter = _RevokingAdapter();

      await AccountManagerNotifier.revokeTokenOnLogout(
        _account(adapter),
        readded: () => true,
      );

      verifyNever(
        () => adapter.revokeOwnToken(
          any(),
          clientSecret: any(named: 'clientSecret'),
        ),
      );
    });

    test('入り直していなければ取り消す', () async {
      final adapter = _RevokingAdapter();
      when(
        () => adapter.revokeOwnToken(
          any(),
          clientSecret: any(named: 'clientSecret'),
        ),
      ).thenAnswer((_) async {});

      await AccountManagerNotifier.revokeTokenOnLogout(
        _account(adapter),
        readded: () => false,
      );

      verify(
        () => adapter.revokeOwnToken(
          any(),
          clientSecret: any(named: 'clientSecret'),
        ),
      ).called(1);
    });

    test('取り消しの口を持たないアダプターでは何もしない', () async {
      await expectLater(
        AccountManagerNotifier.revokeTokenOnLogout(_account(_PlainAdapter())),
        completes,
      );
    });
  });

  // #1420: 取り消しが仕組みとして通っているかを現場で見られるようにする。
  group('取り消しの失敗を Sentry へ送るか', () {
    DioException response(int status) {
      final options = RequestOptions(path: '/oauth/revoke');
      return DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: status),
        type: DioExceptionType.badResponse,
      );
    }

    final mastodon = _MastodonAdapter();
    final misskey = _RevokingAdapter();

    test('⚠⚠ Mastodon 系でサーバーが応答した失敗は送る', () {
      expect(
        AccountManagerNotifier.shouldReportRevokeFailure(
          mastodon,
          response(403),
        ),
        isTrue,
      );
      expect(
        AccountManagerNotifier.shouldReportRevokeFailure(
          mastodon,
          response(500),
        ),
        isTrue,
      );
    });

    test('401（もう失効している）は送らない', () {
      expect(
        AccountManagerNotifier.shouldReportRevokeFailure(
          mastodon,
          response(401),
        ),
        isFalse,
      );
    });

    test('回線の失敗は送らない', () {
      expect(
        AccountManagerNotifier.shouldReportRevokeFailure(
          mastodon,
          DioException(
            requestOptions: RequestOptions(path: '/oauth/revoke'),
            type: DioExceptionType.connectionError,
          ),
        ),
        isFalse,
      );
    });

    test('Mastodon 系でなければ送らない（古い Misskey のエラーは今のまま）', () {
      expect(
        AccountManagerNotifier.shouldReportRevokeFailure(
          misskey,
          response(404),
        ),
        isFalse,
      );
    });
  });

  // ⚠ 順番は「プッシュの登録解除 → 取り消し」。解除は同じトークンで叩くので、
  // 先に取り消すと 401 で落ちて購読が残る。⚠ 取り消す直前に、同じアカウントが
  // 入り直していないかを見る（Mastodon は同じトークンを返す・リリース前レビュー）。
  // ⚠ 判定は合成ソースでも確かめる（docs/CLAUDE.md「ソース検査ガードの書き方」）。
  group('logout は登録解除が終わってから取り消す', () {
    test('実物', () {
      final source = File(
        'lib/src/provider/account_manager_provider.dart',
      ).readAsStringSync();
      expect(
        source,
        contains('Future<void> logout(Account account)'),
        reason: '前提: logout がある',
      );
      expect(logoutRevokeViolation(source), isNull);
    });

    test('判定（合成ソース）', () {
      String logout(String body) =>
          'class X {\n  Future<void> logout(Account account) async {\n'
          '$body\n  }\n}\n';
      const good =
          'unawaited(PushRegistrationService.unregisterAccount(account)'
          '.whenComplete(() => revokeTokenOnLogout(account, '
          'readded: () => _isSignedIn(account.key))));';
      expect(logoutRevokeViolation(logout(good)), isNull);
      expect(
        logoutRevokeViolation(
          logout(
            'unawaited(PushRegistrationService.unregisterAccount(account)'
            '.whenComplete(() => revokeTokenOnLogout(account)));',
          ),
        ),
        isNotNull,
        reason: '入り直しを見ていない',
      );
      expect(
        logoutRevokeViolation(
          logout(
            'await revokeTokenOnLogout(account, readded: () => false);\n'
            'unawaited(PushRegistrationService.unregisterAccount(account));',
          ),
        ),
        isNotNull,
        reason: '解除より先に取り消す',
      );
      expect(
        logoutRevokeViolation(
          logout(
            '// $good\n'
            'await revokeTokenOnLogout(account, readded: () => false);',
          ),
        ),
        isNotNull,
        reason: 'コメントの中の正しい形は数えない',
      );
      expect(logoutRevokeViolation('class X {}'), isNotNull);
    });
  });
}

/// logout の取り消しの呼び方が崩れていれば、その理由。正しければ null。
String? logoutRevokeViolation(String source) {
  final masked = maskComments(source);
  final start = masked.indexOf('Future<void> logout(Account account)');
  if (start < 0) return 'logout が無い';
  final end = masked.indexOf('\n  }\n', start);
  final body = masked.substring(start, end < 0 ? masked.length : end);
  final chained = RegExp(
    r'PushRegistrationService\.unregisterAccount\(\s*account,?\s*\)'
    r'\s*\.whenComplete\(\s*\(\)\s*=>\s*revokeTokenOnLogout\(\s*account\s*,'
    r'\s*readded:',
  );
  if (!chained.hasMatch(body)) return '解除の後に、入り直しを見て取り消していない';
  if ('revokeTokenOnLogout('.allMatches(body).length != 1) {
    return '取り消しを解除とは別に呼んでいる';
  }
  return null;
}

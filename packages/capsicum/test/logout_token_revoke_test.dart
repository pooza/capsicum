// #1401: アカウントの削除で、サーバー側のトークンを取り消す。
import 'dart:io';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _PlainAdapter extends Mock implements DecentralizedBackendAdapter {}

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

    test('取り消しの口を持たないアダプターでは何もしない', () async {
      await expectLater(
        AccountManagerNotifier.revokeTokenOnLogout(_account(_PlainAdapter())),
        completes,
      );
    });
  });

  // ⚠ 順番は「プッシュの登録解除 → 取り消し」。解除は同じトークンで叩くので、
  // 先に取り消すと 401 で落ちて購読が残る。
  test('logout は登録解除が終わってから取り消す', () {
    final source = File(
      'lib/src/provider/account_manager_provider.dart',
    ).readAsStringSync();
    final start = source.indexOf('Future<void> logout(Account account)');
    expect(start, greaterThanOrEqualTo(0), reason: '前提: logout がある');
    final end = source.indexOf('\n  }\n', start);
    final body = source.substring(start, end);
    expect(
      RegExp(
        r'PushRegistrationService\.unregisterAccount\(\s*account,?\s*\)'
        r'\s*\.whenComplete\(\s*\(\)\s*=>\s*revokeTokenOnLogout\(account\)\s*\)',
      ).hasMatch(body),
      isTrue,
    );
    // 取り消しを、解除とは別に（先に・並べて）呼んでいない。
    expect('revokeTokenOnLogout('.allMatches(body), hasLength(1));
  });
}

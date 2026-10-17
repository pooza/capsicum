import 'dart:async';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/service/account_storage.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockStorage extends Mock implements AccountStorage {}

/// #1294 の回帰テスト。
///
/// **接続は受けるが応答を返さないサーバーが 1 台あると、起動の復元が受信
/// タイムアウト（60 秒）まで全体を待ち、スプラッシュから先へ進まなかった。**
/// 報告者は 2 分待つと起動し、そのサーバーのアカウントを外すと待たずに起動した。
///
/// 1 本ずつに締切（[kRestoreStartupDeadline]）を付け、過ぎたものはオフライン保持＋
/// 背景リトライへ回すことを固定する。
void main() {
  const slow = AccountKey(
    type: BackendType.mastodon,
    host: 'silent.example',
    username: 'alice',
  );
  const down = AccountKey(
    type: BackendType.mastodon,
    host: 'down.example',
    username: 'bob',
  );

  setUp(AccountManagerNotifier.resetReportedRestoreErrors);
  tearDown(() => AccountManagerNotifier.debugProbeAccountOverride = null);

  ProviderContainer containerWith(List<AccountKey> keys) {
    final storage = _MockStorage();
    when(
      () => storage.getAccountKeys(),
    ).thenAnswer((_) async => keys.map((k) => k.toStorageKey()).toList());
    when(
      () => storage.getSecrets(any()),
    ).thenAnswer((_) async => {'access_token': 'token'});
    return ProviderContainer(
      overrides: [accountStorageProvider.overrideWithValue(storage)],
    );
  }

  test('⚠⚠ 応答しないサーバーがあっても、締切で復元を抜ける', () {
    fakeAsync((async) {
      // 返さないサーバー（受信タイムアウトまで黙る形）。
      AccountManagerNotifier.debugProbeAccountOverride = (_, _) =>
          Completer<Account>().future;
      final container = containerWith([slow]);

      var done = false;
      container.read(accountManagerProvider.notifier).restoreSessions().then((
        _,
      ) {
        done = true;
      });

      async.elapse(kRestoreStartupDeadline - const Duration(milliseconds: 100));
      expect(done, isFalse, reason: '締切の前には抜けない（遅いだけのサーバーを待つ）');

      async.elapse(const Duration(milliseconds: 200));
      expect(done, isTrue, reason: '受信タイムアウト（60 秒）まで待たない');

      final state = container.read(accountManagerProvider);
      expect(state.offlineAccounts.map((o) => o.key), [slow]);
      expect(
        state.offlineAccounts.single.recoverableByRetry,
        isTrue,
        reason: '背景リトライで拾い直す側（未接続にはしない）',
      );
      expect(state.hasSession, isTrue, reason: '/server へ引き戻さない');

      container.dispose();
    });
  });

  test('締切は全体ではなく 1 本ずつ。速く落ちるものは待たない', () {
    fakeAsync((async) {
      AccountManagerNotifier.debugProbeAccountOverride = (keyStr, _) {
        if (keyStr == down.toStorageKey()) {
          return Future<Account>.error(Exception('not retriable'));
        }
        return Completer<Account>().future;
      };
      final container = containerWith([slow, down]);

      var done = false;
      container.read(accountManagerProvider.notifier).restoreSessions().then((
        _,
      ) {
        done = true;
      });

      async.elapse(kRestoreStartupDeadline + const Duration(milliseconds: 100));
      expect(done, isTrue);
      final state = container.read(accountManagerProvider);
      expect(state.offlineAccounts.map((o) => o.key), [
        slow,
      ], reason: '締切で切ったものだけがオフライン保持になる（もう 1 本は従来の分類）');

      container.dispose();
    });
  });
}

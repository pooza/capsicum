import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/offline_account.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1001: 設定バックアップの取り込みで索引へ足したアカウントを、**再起動を
/// 待たずに**「未接続」として一覧へ出す。
///
/// ⚠ **これが無いと「n 件のアカウントを追加しました」が嘘になる。**索引は
/// `restoreSessions` が起動時に 1 度だけ読むので、実行中に足しても次の起動まで
/// 画面に出ない（Codex P2 / PR #1002）。
void main() {
  const alice = AccountKey(
    type: BackendType.mastodon,
    host: 'mstdn.example',
    username: 'alice',
  );
  const bob = AccountKey(
    type: BackendType.misskey,
    host: 'misskey.example',
    username: 'bob',
  );

  AccountManagerNotifier notifierOf(ProviderContainer container) =>
      container.read(accountManagerProvider.notifier);

  ProviderContainer containerWith(AccountManagerState state) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // build() を走らせてから差し替える（Notifier は state の初期化が要る）。
    container.read(accountManagerProvider);
    notifierOf(container).state = state;
    return container;
  }

  test('未接続として一覧へ足す', () {
    final container = containerWith(const AccountManagerState());

    notifierOf(container).addDisconnectedAccounts([alice, bob]);

    final offline = container.read(accountManagerProvider).offlineAccounts;
    expect(offline.map((o) => o.key), [alice, bob]);
    expect(
      offline.every((o) => o.reason == OfflineAccountReason.secretMissing),
      isTrue,
      reason: 'トークンが無いので probe を組み立てられない＝再試行の対象にしない',
    );
  });

  // ⚠ **背景リトライへ回さない。**トークンが無いので回しても永久に失敗する。
  test('再試行の対象にしない', () {
    final container = containerWith(const AccountManagerState());

    notifierOf(container).addDisconnectedAccounts([alice]);

    final offline = container
        .read(accountManagerProvider)
        .offlineAccounts
        .first;
    expect(offline.recoverableByRetry, isFalse);
  });

  // 取り込みは**マージ**であって置き換えではない。
  test('既にオフラインで居るアカウントは触らない', () {
    final container = containerWith(
      const AccountManagerState(
        offlineAccounts: [OfflineAccount(key: alice, retrying: true)],
      ),
    );

    notifierOf(container).addDisconnectedAccounts([alice, bob]);

    final offline = container.read(accountManagerProvider).offlineAccounts;
    expect(offline.length, 2);
    expect(
      offline.first.reason,
      OfflineAccountReason.unreachable,
      reason: '到達不能で待っている最中のものを未接続へ落とさない',
    );
    expect(offline.last.key, bob);
  });

  test('同じ key を 2 度足しても重複しない', () {
    final container = containerWith(const AccountManagerState());

    notifierOf(container).addDisconnectedAccounts([alice, alice]);

    expect(container.read(accountManagerProvider).offlineAccounts.length, 1);
  });

  test('足すものが無ければ state を作り替えない', () {
    final container = containerWith(const AccountManagerState());
    final before = container.read(accountManagerProvider);

    notifierOf(container).addDisconnectedAccounts(const []);

    expect(identical(container.read(accountManagerProvider), before), isTrue);
  });
}

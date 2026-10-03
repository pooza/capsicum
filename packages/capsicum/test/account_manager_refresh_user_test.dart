import 'dart:async';

import 'package:capsicum/src/constants.dart';
import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1185: Mastodon の既定の公開範囲 (`source.privacy`) が起動時の値で固定される。
///
/// `Account.user` を作るのは `restoreSessions` の `getMyself()` で起動時の 1 回
/// だけだった。以後差し替わるのは capsicum 内でプロフィールを編集したときのみで、
/// **WebUI で既定の公開範囲を変えても再起動まで投稿フォームが古い値で開いた**。
///
/// ⚠ **実質デスクトップの問題。**モバイルは OS がアプリを落とすので再起動で
/// 自然に直るが、デスクトップは常駐するので何日も古いままになりうる。だから
/// 契機はフォアグラウンド復帰。
///
/// ⚠⚠ **ここで固めるのは「引き直すこと」だけではない。**デスクトップは
/// ウィンドウのフォーカスを取り戻すたびに `resumed` が来るので、**間引きが
/// 効いていること**と、**await 中の切替で他人を上書きしないこと**が同じくらい
/// 重要。前者が壊れると alt-tab のたびに 1 往復し、後者が壊れると別アカウントの
/// プロフィールを書き込む。
class _FakeAdapter extends Mock implements DecentralizedBackendAdapter {
  _FakeAdapter(this.user);

  User user;
  bool fail = false;
  int calls = 0;

  /// 非 null なら `getMyself()` はこれが完了するまで待つ（await 中に別の操作を
  /// 挟むためのフック）。
  Completer<void>? gate;

  @override
  Future<User> getMyself() async {
    calls++;
    final gate = this.gate;
    if (gate != null) await gate.future;
    if (fail) throw Exception('server down');
    return user;
  }
}

User _user(String username, {PostScope? scope}) => User(
  id: '1',
  username: username,
  host: 'mstdn.example',
  defaultScope: scope,
);

void main() {
  const alice = AccountKey(
    type: BackendType.mastodon,
    host: 'mstdn.example',
    username: 'alice',
  );
  // ⚠ **同じ host の別アカウント。**TTL を host で持つと、片方の取得でもう片方が
  // 間引かれて「alice を直したら bob が直らない」になる。
  const bob = AccountKey(
    type: BackendType.mastodon,
    host: 'mstdn.example',
    username: 'bob',
  );

  Account accountOf(AccountKey key, _FakeAdapter adapter, {PostScope? scope}) =>
      Account(
        key: key,
        adapter: adapter,
        user: _user(key.username, scope: scope),
        userSecret: const UserSecret(accessToken: 'token'),
      );

  (ProviderContainer, AccountManagerNotifier) boot(AccountManagerState state) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(accountManagerProvider);
    final notifier = container.read(accountManagerProvider.notifier);
    notifier.state = state;
    return (container, notifier);
  }

  test('復帰で引き直すと、既定の公開範囲が新しい値になる', () async {
    final adapter = _FakeAdapter(_user('alice', scope: PostScope.unlisted));
    final (container, notifier) = boot(
      AccountManagerState(
        accounts: [accountOf(alice, adapter, scope: PostScope.public)],
        current: accountOf(alice, adapter, scope: PostScope.public),
      ),
    );

    await notifier.refreshCurrentUser();

    expect(adapter.calls, 1);
    expect(
      container.read(accountManagerProvider).current!.user.defaultScope,
      PostScope.unlisted,
      reason: 'WebUI で変えた値がフォームに出る',
    );
    expect(
      container.read(accountManagerProvider).accounts.single.user.defaultScope,
      PostScope.unlisted,
      reason: '一覧側も揃える（切り替えて戻ると古い値に戻ってはいけない）',
    );
  });

  // ⚠⚠ デスクトップはフォーカスを取り戻すたびに resumed が来る。間引きが無いと
  // alt-tab のたびに 1 往復する。
  test('⚠ TTL 内の 2 回目は叩かない', () async {
    final adapter = _FakeAdapter(_user('alice', scope: PostScope.unlisted));
    final (_, notifier) = boot(
      AccountManagerState(
        accounts: [accountOf(alice, adapter)],
        current: accountOf(alice, adapter),
      ),
    );

    await notifier.refreshCurrentUser();
    await notifier.refreshCurrentUser();
    await notifier.refreshCurrentUser();

    expect(adapter.calls, 1);
  });

  test('force は TTL を無視する', () async {
    final adapter = _FakeAdapter(_user('alice', scope: PostScope.unlisted));
    final (_, notifier) = boot(
      AccountManagerState(
        accounts: [accountOf(alice, adapter)],
        current: accountOf(alice, adapter),
      ),
    );

    await notifier.refreshCurrentUser();
    await notifier.refreshCurrentUser(force: true);

    expect(adapter.calls, 2);
  });

  // ⚠ 一過性の失敗で good な値を捨てない（refreshCurrentServerVersion と同じ方針）。
  test('⚠ 取得に失敗したら既存の値を維持する', () async {
    final adapter = _FakeAdapter(_user('alice', scope: PostScope.unlisted))
      ..fail = true;
    final (container, notifier) = boot(
      AccountManagerState(
        accounts: [accountOf(alice, adapter, scope: PostScope.public)],
        current: accountOf(alice, adapter, scope: PostScope.public),
      ),
    );

    await notifier.refreshCurrentUser();

    expect(adapter.calls, 1);
    expect(
      container.read(accountManagerProvider).current!.user.defaultScope,
      PostScope.public,
      reason: 'null や既定値に落とすと、投稿先が黙って変わる',
    );
  });

  // ⚠⚠ **これが本丸。**updateCurrentUser は `state.current` をそのまま書き換える
  // ので、await 中に切替が起きた状態でそれを使うと**切替後のアカウントへ他人の
  // user を書き込む**。key で引き直していることを固定する。
  test('⚠⚠ await 中にアカウントを切り替えても、別アカウントを上書きしない', () async {
    final aliceAdapter = _FakeAdapter(_user('alice', scope: PostScope.unlisted))
      ..gate = Completer<void>();
    final bobAdapter = _FakeAdapter(
      _user('bob', scope: PostScope.followersOnly),
    );

    final aliceAccount = accountOf(
      alice,
      aliceAdapter,
      scope: PostScope.public,
    );
    final bobAccount = accountOf(
      bob,
      bobAdapter,
      scope: PostScope.followersOnly,
    );
    final (container, notifier) = boot(
      AccountManagerState(
        accounts: [aliceAccount, bobAccount],
        current: aliceAccount,
      ),
    );

    final pending = notifier.refreshCurrentUser();
    // getMyself の最中に bob へ切り替える。
    notifier.state = container
        .read(accountManagerProvider)
        .copyWith(current: bobAccount);
    aliceAdapter.gate!.complete();
    await pending;

    final state = container.read(accountManagerProvider);
    expect(state.current!.key, bob, reason: '切替そのものを巻き戻してはいけない');
    expect(
      state.current!.user.username,
      'bob',
      reason: '⚠⚠ ここが alice になるのが、state.current を直接書き換えたときの壊れ方',
    );
    expect(
      state.current!.user.defaultScope,
      PostScope.followersOnly,
      reason: 'bob の既定が alice の値で塗り替えられない',
    );
    expect(
      state.accounts.firstWhere((a) => a.key == alice).user.defaultScope,
      PostScope.unlisted,
      reason: '取り直した alice のぶんは、一覧側には正しく入る',
    );
  });

  // ⚠ TTL を host で持つと、同じサーバーの 2 アカウント目が間引かれる。
  test('⚠ 同じ host の別アカウントは TTL を共有しない', () async {
    final aliceAdapter = _FakeAdapter(
      _user('alice', scope: PostScope.unlisted),
    );
    final bobAdapter = _FakeAdapter(_user('bob', scope: PostScope.unlisted));
    final aliceAccount = accountOf(alice, aliceAdapter);
    final bobAccount = accountOf(bob, bobAdapter);
    final (container, notifier) = boot(
      AccountManagerState(
        accounts: [aliceAccount, bobAccount],
        current: aliceAccount,
      ),
    );

    await notifier.refreshCurrentUser();
    notifier.state = container
        .read(accountManagerProvider)
        .copyWith(current: bobAccount);
    await notifier.refreshCurrentUser();

    expect(aliceAdapter.calls, 1);
    expect(bobAdapter.calls, 1, reason: 'alice の取得で bob の TTL を消費しない');
  });

  // 定数そのものの固定。1 時間（サーバーメタデータ側）を流用すると、
  // 「WebUI で変えて戻る」をほぼ毎回取りこぼす。
  test('⚠ TTL はサーバーメタデータの 1 時間と別物', () {
    expect(kUserProfileFreshnessTtl, const Duration(minutes: 1));
    expect(kUserProfileFreshnessTtl, lessThan(kServerMetadataFreshnessTtl));
  });
}

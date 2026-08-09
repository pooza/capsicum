import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/offline_account.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter_test/flutter_test.dart';

/// `AccountManagerState.hasSession` を固定する (#917)。
///
/// 「オフライン保持だけが残っている状態はログアウトではない」という判定は
/// splash（`/home` か `/server` かの分岐）と router の redirect の**両方**で
/// 要る。#792 は splash にしか入れておらず、splash が `/home` へ送った直後に
/// redirect が `/server` へ引き戻していた。二度と分岐が割れないよう、判定を
/// 1 箇所に寄せた上でここで契約として固定する。
void main() {
  const key = AccountKey(
    type: BackendType.mastodon,
    host: 'mstdn.example',
    username: 'alice',
  );

  group('AccountManagerState.hasSession (#917)', () {
    test('アカウントも offline 保持も無ければ false（本当のログアウト）', () {
      const state = AccountManagerState();
      expect(state.hasSession, isFalse);
    });

    test('offline 保持だけがあるなら true（オフライン起動・サーバー停止中）', () {
      const state = AccountManagerState(
        offlineAccounts: [OfflineAccount(key: key)],
      );
      // current は null のまま。ここで false になると router が /server へ
      // 引き戻し、ログアウトしたように見える。
      expect(state.current, isNull);
      expect(state.hasSession, isTrue);
    });

    test('retrying=false（再試行の合間）でも true のまま', () {
      // #938 で `retrying` の意味は「背景 backoff がまだ残っている」から
      // 「この瞬間 probe が走っている」へ変わった。false は「自動再試行を
      // 諦めた」ではなく単に周回の合間なので、ここが false に転ぶと
      // 待っている間だけログイン画面へ飛ばされることになる。
      const state = AccountManagerState(
        offlineAccounts: [OfflineAccount(key: key, retrying: false)],
      );
      expect(state.hasSession, isTrue);
    });

    test('offline 保持が空になれば false へ戻る（ログアウト経路）', () {
      const state = AccountManagerState(
        offlineAccounts: [OfflineAccount(key: key)],
      );
      final loggedOut = state.copyWith(offlineAccounts: const []);
      expect(loggedOut.hasSession, isFalse);
    });
  });
}

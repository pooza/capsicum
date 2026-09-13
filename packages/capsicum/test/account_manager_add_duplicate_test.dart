import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1110: ログイン済みのアカウントを足し直しても一覧に 2 件並ばないようにする。
///
/// ⚠ **再起動すると 1 件に戻るので気づきにくい不具合だった。**索引側
/// （`AccountStorage.addAccount`）は `contains` で弾いており、起動時はそこから
/// 読み直すため。メモリ側だけが弾いていなかった。
///
/// ⚠ **オフライン保持 entry の重複排除 (#792) と対になっている。**片方だけ直すと
/// また同じ形の漏れになるので、両方が同じ判定（キー一致で落とす）であることを
/// 崩さない。
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

  /// ⚠ **同じ `username@host` でも type が違えば別アカウント**（AccountKey は
  /// 3 つ組で等価判定する）。落とす条件がホスト名だけに緩まないことを見る。
  const aliceOnMisskey = AccountKey(
    type: BackendType.misskey,
    host: 'mstdn.example',
    username: 'alice',
  );

  Future<Account> accountOf(AccountKey key, {String? version}) async => Account(
    key: key,
    adapter: key.type == BackendType.mastodon
        ? await MastodonAdapter.create(key.host)
        : await MisskeyAdapter.create(key.host),
    user: User(id: '1', username: key.username, host: key.host),
    userSecret: const UserSecret(accessToken: 'token'),
    softwareVersion: version,
  );

  test('同じキーのアカウントを足し直しても 1 件のまま', () async {
    final existing = [await accountOf(alice), await accountOf(bob)];

    final merged = withAccountAtFront(existing, await accountOf(alice));

    expect(merged.length, 2);
    expect(merged.map((a) => a.key), [alice, bob]);
  });

  test('⚠ 足し直した方（新しい方）が残る', () async {
    // 再ログインで取り直した情報を、古い entry で上書きし返さないことの確認。
    final existing = [await accountOf(alice, version: '4.7.0')];

    final merged = withAccountAtFront(
      existing,
      await accountOf(alice, version: '4.7.1'),
    );

    expect(merged.single.softwareVersion, '4.7.1');
  });

  test('別のアカウントは落とさない（先頭へ足すだけ）', () async {
    final merged = withAccountAtFront([
      await accountOf(alice),
    ], await accountOf(bob));

    expect(merged.map((a) => a.key), [bob, alice]);
  });

  test('⚠ host と username が同じでも backend が違えば別アカウント', () async {
    final merged = withAccountAtFront([
      await accountOf(alice),
    ], await accountOf(aliceOnMisskey));

    expect(merged.map((a) => a.key), [aliceOnMisskey, alice]);
  });

  test('空の一覧に足せる', () async {
    expect(
      withAccountAtFront(const [], await accountOf(alice)).single.key,
      alice,
    );
  });
}

import 'package:capsicum/src/service/account_storage.dart';
import 'package:capsicum/src/service/settings_backup.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1012: 取り込みで索引へ書き戻す key に、**残骸トークンが残っていないこと**。
///
/// ⚠ **これが無いと、削除したアカウントが完全ログイン状態で復活する。**
/// [AccountStorage.removeAccount] は secret の delete に失敗しても索引を消す
/// （Linux libsecret の非 op delete＝#621 が実在し、`delete_no_op` として計装
/// 済み）。索引から消えている間は誰も参照しないので無害だが、**削除前に取った
/// バックアップを取り込むと索引だけが復活して残骸と再会する**。次回起動の
/// `restoreSessions` はそれで probe に成功するので、UI は #967 に従って
/// 「未接続」と言っているのに実態は完全ログイン、という食い違いになる。
///
/// #1001 は「取り込んだアカウントはトークンを持たない」と宣言しているので、
/// **宣言する側で成り立たせる**（`_mergeAccounts` が `purgeStaleSecrets` を呼ぶ）。
class _FakeSecureStorage extends FlutterSecureStorage {
  _FakeSecureStorage(this._data);

  final Map<String, String> _data;
  final List<String> deletes = [];

  /// これらの key への delete を**黙って無視する**（#621 の非 op delete を再現）。
  final Set<String> ignoreDeleteFor = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _data[key];

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _data.containsKey(key);

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deletes.add(key);
    if (ignoreDeleteFor.contains(key)) return;
    _data.remove(key);
  }
}

/// plugin を差し替えていない環境（register race #488 / secure storage を
/// 用意していないテスト）を再現する。
class _MissingPluginStorage extends FlutterSecureStorage {
  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw MissingPluginException('no impl for containsKey');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const alice = 'mastodon://alice@mstdn.example';
  const bob = 'misskey://bob@misskey.example';

  String yamlWith(List<String> accounts) =>
      '''
version: 1
accounts:
${accounts.map((a) => '  - $a').join('\n')}
settings: {}
''';

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  test('取り込みで書き戻す key の残骸トークンは消す', () async {
    final prefs = await prefsWith({});
    // 索引には居ないのに secret だけ生きている＝削除時に delete が非 op だった
    // 端末の状態。
    final fake = _FakeSecureStorage({'secret_$alice': 'stale-token'});

    final result = await applySettingsBackupYaml(
      prefs,
      yamlWith([alice]),
      accountStorage: AccountStorage(fake),
    );

    expect(result.addedAccountKeys, [alice]);
    expect(
      fake._data.containsKey('secret_$alice'),
      isFalse,
      reason: '残すと、次回起動の restoreSessions が完全ログイン状態へ戻す',
    );
  });

  // 索引へ足さない相手（既に居る / ファイルに無い）の secret には触らない。
  // ここを広げると、取り込みのたびに手元のログインが飛ぶ。
  test('書き戻さない key の secret は触らない', () async {
    final prefs = await prefsWith({AccountStorage.accountListKey: '["$bob"]'});
    final fake = _FakeSecureStorage({
      'secret_$alice': 'stale-token',
      'secret_$bob': 'live-token',
    });

    final result = await applySettingsBackupYaml(
      prefs,
      yamlWith([alice, bob]),
      accountStorage: AccountStorage(fake),
    );

    expect(result.addedAccountKeys, [alice], reason: 'bob は既に索引に居る');
    expect(
      fake._data['secret_$bob'],
      'live-token',
      reason: 'ログイン中のアカウントのトークンを巻き添えにしてはいけない',
    );
    expect(fake.deletes, isNot(contains('secret_$bob')));
  });

  // 残骸が無いのが普通。無駄な delete を撃たない（観測も汚さない）。
  test('残骸が無ければ delete しない', () async {
    final prefs = await prefsWith({});
    final fake = _FakeSecureStorage({});

    await applySettingsBackupYaml(
      prefs,
      yamlWith([alice]),
      accountStorage: AccountStorage(fake),
    );

    expect(fake.deletes, isEmpty);
  });

  // ⚠ **消せなかったときに索引を書いてはいけない。** 書くと「索引あり +
  // 残骸トークンあり」という、この修正が塞ごうとしている状態そのものになる。
  test('残骸を消せなければ索引を書き戻さない', () async {
    final prefs = await prefsWith({});
    final fake = _FakeSecureStorage({'secret_$alice': 'stale-token'})
      ..ignoreDeleteFor.add('secret_$alice');

    final result = await applySettingsBackupYaml(
      prefs,
      yamlWith([alice]),
      accountStorage: AccountStorage(fake),
    );

    expect(result.addedAccountKeys, isEmpty);
    expect(
      prefs.getString(AccountStorage.accountListKey),
      isNot(contains(alice)),
      reason: '索引を書くと、残骸トークンで復活する状態が完成してしまう',
    );
    expect(
      result.skipped['accounts'],
      isNotNull,
      reason: '黙って落とさず、取り込めなかった理由をユーザーへ返す',
    );
  });

  // plugin が居ない環境では諦めて素通しする。消せなかったぶんは「元のまま」で、
  // この関数を入れる前と同じ状態にしかならない。
  test('plugin 未登録なら取り込みを止めない', () async {
    final prefs = await prefsWith({});

    final result = await applySettingsBackupYaml(
      prefs,
      yamlWith([alice]),
      accountStorage: AccountStorage(_MissingPluginStorage()),
    );

    expect(result.addedAccountKeys, [alice]);
  });
}

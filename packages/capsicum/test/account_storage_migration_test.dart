import 'package:capsicum/src/service/account_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// AccountStorage.migrateAccessibilityIfNeeded (#643) の owned-key 限定と
/// flag gate を、in-memory な FlutterSecureStorage fake で固定する。
/// 実際の Keychain accessibility 焼き直しは内部ベータ / 実機検証で確認する。
class _FakeSecureStorage extends FlutterSecureStorage {
  _FakeSecureStorage(this._data);

  final Map<String, String> _data;
  final List<String> deletes = [];
  final List<String> writes = [];

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map<String, String>.of(_data);

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes.add(key);
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
  }

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
    _data.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const flagKey = 'account_storage_accessibility_migrated_v1';

  test('owned key のみ焼き直し（非 owned key には触れない）、flag を立てる', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final fake = _FakeSecureStorage({
      'secret_mastodon://a@h': 's1',
      'client_creds_h': 'c1',
      'capsicum_account_keys': '["mastodon://a@h"]', // legacy index
      'unrelated_other_key': 'x',
    });

    await AccountStorage(fake).migrateAccessibilityIfNeeded();

    const owned = [
      'secret_mastodon://a@h',
      'client_creds_h',
      'capsicum_account_keys',
    ];
    expect(fake.deletes, containsAll(owned));
    expect(fake.writes, containsAll(owned));
    // 値は保持されている（delete 後に同値で write される）。
    expect(fake._data['secret_mastodon://a@h'], 's1');
    // 非 owned key は素通り。
    expect(fake.deletes, isNot(contains('unrelated_other_key')));
    expect(fake.writes, isNot(contains('unrelated_other_key')));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(flagKey), isTrue);
  });

  test('flag が既に立っていれば no-op', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{flagKey: true});
    final fake = _FakeSecureStorage({'secret_x': 's'});

    await AccountStorage(fake).migrateAccessibilityIfNeeded();

    expect(fake.deletes, isEmpty);
    expect(fake.writes, isEmpty);
  });
}

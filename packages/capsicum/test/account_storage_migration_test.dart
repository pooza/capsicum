import 'package:capsicum/src/service/account_storage.dart';
import 'package:flutter/services.dart';
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

  /// これらの key への次回 write で 1 度だけ -25299 を投げる（重複リカバリ
  /// 経路の検証用）。発火後に key を除去するので、delete→再 write は成功する。
  final Set<String> throwDuplicateOnceFor = {};

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
    if (throwDuplicateOnceFor.remove(key)) {
      throw PlatformException(
        code: '-25299',
        message: '指定された項目はキーチェーン内にすでに存在します。',
      );
    }
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

  const flagKey = 'account_storage_accessibility_migrated_v2';

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

  test('saveAccount: write が -25299 を投げたら delete してから書き直す', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final fake = _FakeSecureStorage({});
    const key = 'secret_mastodon://a@h';
    fake.throwDuplicateOnceFor.add(key);

    await AccountStorage(fake).saveAccount('mastodon://a@h', {'token': 't'});

    // 初回 write が -25299 → delete → 再 write で成立。
    expect(fake.deletes, contains(key));
    expect(fake.writes, contains(key));
    expect(fake._data[key], '{"token":"t"}');
  });

  test('saveHostClientCredentials: -25299 でも delete+retry で書き込める', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final fake = _FakeSecureStorage({});
    const key = 'client_creds_h';
    fake.throwDuplicateOnceFor.add(key);

    await AccountStorage(
      fake,
    ).saveHostClientCredentials('h', 'cid', 'csecret', 'capsicum://oauth');

    expect(fake.deletes, contains(key));
    expect(fake._data[key], isNotNull);
  });

  test('getHostClientCredentials: redirect_uri 一致時のみ返す', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final fake = _FakeSecureStorage({});
    final storage = AccountStorage(fake);
    await storage.saveHostClientCredentials(
      'h',
      'cid',
      'csec',
      'capsicum://oauth',
    );

    // 別 era の redirect_uri では stale 扱いで null。
    expect(
      await storage.getHostClientCredentials(
        'h',
        'http://localhost:7099/oauth/callback',
      ),
      isNull,
    );
    // 一致すれば返す。
    final ok = await storage.getHostClientCredentials('h', 'capsicum://oauth');
    expect(ok?.clientId, 'cid');
  });

  test('getHostClientCredentials: redirect_uri 欄の無い旧 cache は null', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final fake = _FakeSecureStorage({
      'client_creds_h': '{"client_id":"old","client_secret":"s"}',
    });
    expect(
      await AccountStorage(fake).getHostClientCredentials(
        'h',
        'http://localhost:7099/oauth/callback',
      ),
      isNull,
    );
  });
}

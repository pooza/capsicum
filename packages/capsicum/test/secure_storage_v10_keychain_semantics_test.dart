import 'dart:convert';

import 'package:capsicum/src/platform/platform_info.dart';
import 'package:capsicum/src/service/account_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1120: `flutter_secure_storage` 10 の Keychain の振る舞いの下で、
/// accessibility の移行 (#643) がトークンを失わないことを固定する。
///
/// ## ⚠⚠ 9.x から何が変わったか
///
/// 10 の darwin 実装（`flutter_secure_storage_darwin`）は、**`delete` で
/// accessibility を外して問い合わせる**（`performDelete` の
/// `modifiedParams.accessibilityLevel = nil`）。9.x は accessibility ごとの
/// 区画だけを消していたので、**「旧区画を消す」つもりの delete が新区画まで消す**。
///
/// capsicum の移行は「新区画へ書く → 旧区画を消す」順だと**書いたばかりの
/// トークンが消える**。実装は「消す → 書く」順なので安全なはずで、それを
/// Keychain の実際の規則（下の fake）で確かめる。
///
/// ## fake が真似る Keychain の規則
///
/// - item の同一性は**キーだけ**で決まる（accessibility は主キーに入らない）。
///   区画違いでも同じキーを足すと `errSecDuplicateItem`（-25299）
/// - `read` / `readAll` は**問い合わせた accessibility の item しか返さない**
///   （darwin 0.3.x。0.4.3 の「他区画へのフォールバック」は入っていない）
/// - `delete` は **accessibility を問わず**同じキーを消す（10 の変更点）
class _KeychainV10Fake extends FlutterSecureStorage {
  /// key → (accessibility, value)
  final Map<String, (KeychainAccessibility, String)> items = {};

  /// 既定の区画（`AccountStorage` の既定 = `first_unlock`）。
  static const _defaultLevel = KeychainAccessibility.first_unlock;

  KeychainAccessibility _level(AppleOptions? o) =>
      o?.accessibility ?? _defaultLevel;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final item = items[key];
    if (item == null || item.$1 != _level(iOptions)) return null;
    return item.$2;
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => await read(key: key, iOptions: iOptions) != null;

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => {
    for (final e in items.entries)
      if (e.value.$1 == _level(iOptions)) e.key: e.value.$2,
  };

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final level = _level(iOptions);
    final existing = items[key];
    if (value == null) {
      items.remove(key);
      return;
    }
    if (existing != null && existing.$1 != level) {
      // 同じ区画なら SecItemUpdate で済む。違う区画の同じキーは Add が重複で落ちる。
      throw PlatformException(code: '-25299', message: 'errSecDuplicateItem');
    }
    items[key] = (level, value);
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    // ⚠⚠ 10 の変更点: accessibility を問わず消す。
    items.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugKeychainAccessibilityOverride = true;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(() => debugKeychainAccessibilityOverride = null);

  const accountKey = 'mastodon://a@h';
  const secretKey = 'secret_$accountKey';
  const legacy = KeychainAccessibility.unlocked;
  const current = KeychainAccessibility.first_unlock;

  test('旧区画のトークンが、移行後に新区画で読める', () async {
    final fake = _KeychainV10Fake();
    fake.items[secretKey] = (legacy, '{"token":"t"}');
    fake.items['client_creds_h'] = (legacy, '{"client_id":"c"}');

    await AccountStorage(fake).migrateAccessibilityIfNeeded();

    expect(fake.items[secretKey], (current, '{"token":"t"}'));
    expect(fake.items['client_creds_h'], (current, '{"client_id":"c"}'));
  });

  test('⚠ 新区画に書いてから旧区画を消す順だと失う（fake の歯）', () async {
    // 移行の順序が逆になったらこうなる、を fake で再現する。これが通らなければ
    // fake が 10 の delete を真似ておらず、上のテストは何も見ていない。
    final fake = _KeychainV10Fake();
    fake.items[secretKey] = (legacy, 'v');
    await fake.delete(key: secretKey); // 先に消さないと write は重複で落ちる
    await fake.write(key: secretKey, value: 'v');
    await fake.delete(
      key: secretKey,
      iOptions: const IOSOptions(accessibility: legacy),
    );
    expect(fake.items.containsKey(secretKey), isFalse);
  });

  test('旧区画に同じキーが残っていても、保存（重複からの回復）でトークンを失わない', () async {
    final fake = _KeychainV10Fake();
    fake.items[secretKey] = (legacy, '{"token":"old"}');

    await AccountStorage(fake).saveAccount(accountKey, {'token': 'new'});

    final stored = fake.items[secretKey];
    expect(stored?.$1, current);
    expect(jsonDecode(stored!.$2), containsPair('token', 'new'));
    expect(await AccountStorage(fake).getSecrets(accountKey), {'token': 'new'});
  });
}

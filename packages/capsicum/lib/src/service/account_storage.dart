import 'dart:convert';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists account secrets.
///
/// Secrets (`secret_<key>`, `client_creds_<host>`) live in
/// flutter_secure_storage. The list of account keys itself is non-sensitive
/// (host + username) and lives in shared_preferences. Splitting the index out
/// prevents "single point of failure" behaviour where a corrupted Keystore
/// entry for the index wipes every account.
class AccountStorage {
  static const _legacyAccountListKey = 'capsicum_account_keys';
  static const _accountListKey = 'capsicum_account_keys_v2';

  final FlutterSecureStorage _storage;

  /// Deduplicates Sentry reports within the process so the same Keystore
  /// breakage isn't reported once per account × app launch. Keyed by
  /// `(stage, runtimeType)` where stage is `index` or `secret:<account>`.
  static final Set<String> _reportedErrors = {};

  AccountStorage([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  /// Save access token and optional client credentials for an account.
  Future<void> saveAccount(
    String accountKey,
    Map<String, String> secrets,
  ) async {
    await _storage.write(key: 'secret_$accountKey', value: jsonEncode(secrets));
    final list = await getAccountKeys();
    if (!list.contains(accountKey)) {
      list.add(accountKey);
      await _writeIndex(list);
    }
  }

  /// Retrieve stored secrets for an account.
  Future<Map<String, String>?> getSecrets(String accountKey) async {
    try {
      final raw = await _storage.read(key: 'secret_$accountKey');
      if (raw == null) return null;
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } on PlatformException catch (e, st) {
      debugPrint('capsicum: failed to read secrets for $accountKey: $e');
      _reportOnce('secret:$accountKey', e, st);
      await _storage.delete(key: 'secret_$accountKey');
      return null;
    } catch (e, st) {
      // BadPaddingException etc. may bypass PlatformException wrapping
      // after app reinstall (encryption key regenerated).
      debugPrint(
        'capsicum: unexpected error reading secrets for $accountKey: $e',
      );
      _reportOnce('secret:$accountKey', e, st);
      await _storage.delete(key: 'secret_$accountKey');
      return null;
    }
  }

  /// Get all stored account keys.
  ///
  /// Reads from shared_preferences. On first run after upgrading from
  /// pre-v1.19 the index lived in secure storage; a one-time migration
  /// copies it over so existing users don't lose their account list.
  Future<List<String>> getAccountKeys() async {
    final prefs = await _prefs();
    final encoded = prefs.getString(_accountListKey);
    if (encoded != null) {
      try {
        return List<String>.from(jsonDecode(encoded) as List);
      } catch (e) {
        // shared_preferences 上での JSON 破損は極めて稀だが、出たら空に
        // して前進する（Sentry には出さない。secure_storage ほどの信号
        // 価値がないため）。
        debugPrint('capsicum: failed to parse account keys: $e');
        await prefs.remove(_accountListKey);
        return [];
      }
    }

    // legacy: secure_storage から 1 度だけ移行。失敗時はインデックスだけ
    // 諦めて空にし、個別の secret_<key> はそのまま残す（アカウント
    // 再ログインで復元できる）。
    try {
      final raw = await _storage.read(key: _legacyAccountListKey);
      if (raw == null) return [];
      final list = List<String>.from(jsonDecode(raw) as List);
      await _writeIndex(list);
      await _storage.delete(key: _legacyAccountListKey);
      return list;
    } on PlatformException catch (e, st) {
      _reportOnce('index', e, st);
      await _storage.delete(key: _legacyAccountListKey);
      return [];
    } catch (e, st) {
      _reportOnce('index', e, st);
      await _storage.delete(key: _legacyAccountListKey);
      return [];
    }
  }

  /// Move an account key to the front of the list (MRU tracking).
  Future<void> touchAccount(String accountKey) async {
    final list = await getAccountKeys();
    if (!list.contains(accountKey)) return;
    list.remove(accountKey);
    list.insert(0, accountKey);
    await _writeIndex(list);
  }

  /// Remove an account.
  Future<void> removeAccount(String accountKey) async {
    await _storage.delete(key: 'secret_$accountKey');
    final list = await getAccountKeys();
    list.remove(accountKey);
    await _writeIndex(list);
  }

  /// Save OAuth client credentials for a host (survives account deletion).
  Future<void> saveHostClientCredentials(
    String host,
    String clientId,
    String clientSecret,
  ) async {
    final data = jsonEncode({
      'client_id': clientId,
      'client_secret': clientSecret,
    });
    await _storage.write(key: 'client_creds_$host', value: data);
  }

  /// Retrieve OAuth client credentials for a host.
  Future<ClientSecretData?> getHostClientCredentials(String host) async {
    try {
      final raw = await _storage.read(key: 'client_creds_$host');
      if (raw == null) return null;
      final map = Map<String, String>.from(jsonDecode(raw) as Map);
      return ClientSecretData(
        clientId: map['client_id']!,
        clientSecret: map['client_secret']!,
      );
    } catch (e) {
      debugPrint('capsicum: failed to read client credentials for $host: $e');
      return null;
    }
  }

  Future<void> _writeIndex(List<String> keys) async {
    final prefs = await _prefs();
    await prefs.setString(_accountListKey, jsonEncode(keys));
  }

  static void _reportOnce(String stage, Object error, StackTrace st) {
    final key = '$stage:${error.runtimeType}';
    if (!_reportedErrors.add(key)) return;
    Sentry.captureException(error, stackTrace: st);
  }
}

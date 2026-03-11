import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists account secrets to flutter_secure_storage.
class AccountStorage {
  static const _accountListKey = 'capsicum_account_keys';
  final FlutterSecureStorage _storage;

  AccountStorage([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  /// Save access token and optional client credentials for an account.
  Future<void> saveAccount(
    String accountKey,
    Map<String, String> secrets,
  ) async {
    await _storage.write(key: 'secret_$accountKey', value: jsonEncode(secrets));
    final list = await getAccountKeys();
    if (!list.contains(accountKey)) {
      list.add(accountKey);
      await _storage.write(key: _accountListKey, value: jsonEncode(list));
    }
  }

  /// Retrieve stored secrets for an account.
  Future<Map<String, String>?> getSecrets(String accountKey) async {
    final raw = await _storage.read(key: 'secret_$accountKey');
    if (raw == null) return null;
    return Map<String, String>.from(jsonDecode(raw) as Map);
  }

  /// Get all stored account keys.
  Future<List<String>> getAccountKeys() async {
    final raw = await _storage.read(key: _accountListKey);
    if (raw == null) return [];
    return List<String>.from(jsonDecode(raw) as List);
  }

  /// Move an account key to the front of the list (MRU tracking).
  Future<void> touchAccount(String accountKey) async {
    final list = await getAccountKeys();
    if (!list.contains(accountKey)) return;
    list.remove(accountKey);
    list.insert(0, accountKey);
    await _storage.write(key: _accountListKey, value: jsonEncode(list));
  }

  /// Remove an account.
  Future<void> removeAccount(String accountKey) async {
    await _storage.delete(key: 'secret_$accountKey');
    final list = await getAccountKeys();
    list.remove(accountKey);
    await _storage.write(key: _accountListKey, value: jsonEncode(list));
  }
}

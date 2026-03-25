import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

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
    try {
      final raw = await _storage.read(key: 'secret_$accountKey');
      if (raw == null) return null;
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } on PlatformException catch (e, st) {
      debugPrint('capsicum: failed to read secrets for $accountKey: $e');
      Sentry.captureException(e, stackTrace: st);
      await _storage.delete(key: 'secret_$accountKey');
      return null;
    } catch (e, st) {
      // BadPaddingException etc. may bypass PlatformException wrapping
      // after app reinstall (encryption key regenerated).
      debugPrint(
        'capsicum: unexpected error reading secrets for $accountKey: $e',
      );
      Sentry.captureException(e, stackTrace: st);
      await _storage.delete(key: 'secret_$accountKey');
      return null;
    }
  }

  /// Get all stored account keys.
  Future<List<String>> getAccountKeys() async {
    try {
      final raw = await _storage.read(key: _accountListKey);
      if (raw == null) return [];
      return List<String>.from(jsonDecode(raw) as List);
    } on PlatformException catch (e, st) {
      debugPrint('capsicum: failed to read account keys: $e');
      Sentry.captureException(e, stackTrace: st);
      await _storage.deleteAll();
      return [];
    } catch (e, st) {
      debugPrint('capsicum: unexpected error reading account keys: $e');
      Sentry.captureException(e, stackTrace: st);
      await _storage.deleteAll();
      return [];
    }
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

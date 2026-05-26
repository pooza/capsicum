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
      final raw = await _readWithRegisterRetry('secret_$accountKey');
      if (raw == null) return null;
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } on MissingPluginException catch (e, st) {
      // plugin register race が retry 後も解消しないケース。同じ race で
      // delete も失敗するため、ここでは観測のみ行い secret は残す。
      // 次回起動で再試行される。
      debugPrint(
        'capsicum: plugin register race persisted for $accountKey: $e',
      );
      _reportOnce('secret:$accountKey', e, st);
      return null;
    } on PlatformException catch (e, st) {
      // macOS / iOS の Keychain ロック (errSecInteractionNotAllowed = -25308)
      // は **transient** で、画面解錠後に再起動すれば読めるはずなので
      // delete してはいけない。launch-at-login や連続再起動でユーザーが
      // 画面ロック解除前にアプリが起動した場合などで観測される
      // (CAPSICUM-1M, #531)。
      if (_isKeychainTransient(e)) {
        debugPrint(
          'capsicum: keychain transient for $accountKey (code=${e.code}): $e',
        );
        _reportOnce('secret:$accountKey:transient', e, st);
        return null;
      }
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

  /// flutter_secure_storage の MethodChannel が plugin register より先に
  /// 叩かれた場合、Linux では `MissingPluginException` で帰る。これは
  /// `gtk_widget_realize` が Flutter engine を起動した直後に
  /// `_SplashScreenState.initState` から `restoreSessions` が走ると、
  /// runner 側 `fl_register_plugins` の完了とレースするため (#488)。
  ///
  /// runner の register 自体は同期で短時間に完了するので、短いインターバル
  /// で数回リトライすれば十分塞げる。Mastodon / Misskey 共通経路で
  /// アカウント復元の信頼性を底上げするため、storage 層に閉じ込めて配置。
  ///
  /// `MissingPluginException` は `PlatformException` を継承していないため、
  /// retry 後も解消しない場合はそのまま re-throw して呼び出し側
  /// (`getSecrets`) の専用 catch で処理する。
  Future<String?> _readWithRegisterRetry(String key) async {
    // 50 + 100 + 200 + 250 = 600ms。低スペック端末 / cold start で plugin
    // register が遅れる場合に備え、合計を約 600ms に延長 (#497)。
    const delaysMs = [50, 100, 200, 250];
    MissingPluginException? lastMissing;
    for (final delayMs in delaysMs) {
      try {
        return await _storage.read(key: key);
      } on MissingPluginException catch (e) {
        lastMissing = e;
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
    }
    // 最後にもう 1 回試す (delay 累計後)。
    try {
      return await _storage.read(key: key);
    } on MissingPluginException catch (e) {
      lastMissing = e;
    }
    throw lastMissing;
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

    // legacy: secure_storage から 1 度だけ移行。shared_preferences への
    // 書き込みが成功して初めて legacy key を削除する。write 側で失敗した
    // ときまで legacy を消すと、transient な prefs 書き込みエラーで
    // 全アカウントインデックスを永久に失う（Codex 指摘）。write 成功前の
    // 失敗時は legacy をそのまま残し、次回起動で自動リトライされるように
    // する。parse 失敗は legacy データ自体が壊れているので削除してよい。
    List<String> list;
    try {
      final raw = await _storage.read(key: _legacyAccountListKey);
      if (raw == null) return [];
      list = List<String>.from(jsonDecode(raw) as List);
    } on PlatformException catch (e, st) {
      // secure_storage 読み込み失敗。legacy は残して次回リトライ。
      _reportOnce('index', e, st);
      return [];
    } catch (e, st) {
      // JSON parse 失敗等。legacy データ自体が壊れているので削除。
      _reportOnce('index', e, st);
      await _storage.delete(key: _legacyAccountListKey);
      return [];
    }
    try {
      await _writeIndex(list);
    } catch (e, st) {
      // shared_preferences 書き込み失敗。legacy を残して次回再試行。
      _reportOnce('index', e, st);
      return list;
    }
    // ここまで来たら新 index への書き込みが完了している。legacy を削除。
    await _storage.delete(key: _legacyAccountListKey);
    return list;
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

  /// Drop the cached OAuth client credentials for a host.
  ///
  /// Mastodon は client_id ごとに登録済 redirect_uris を厳格 match する。
  /// 旧版 (#489 前) に capsicum://oauth のみで登録された cache が残ったまま
  /// 新版 (http://localhost:7099/oauth/callback) でログインしようとすると
  /// `invalid_redirect_uri` でサーバ側がエラーページを返す (#620)。
  /// login_screen のサイレント再登録経路で使う。
  Future<void> deleteHostClientCredentials(String host) async {
    await _storage.delete(key: 'client_creds_$host');
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
    } catch (e, st) {
      // getSecrets と同じ Linux Keystore race (#488) や OS 鍵ローテーション
      // (BadPaddingException) が host_credentials 側で発火しても観測できる
      // よう、_reportOnce 経路に揃える (#501)。
      debugPrint('capsicum: failed to read client credentials for $host: $e');
      _reportOnce('client_creds:$host', e, st);
      return null;
    }
  }

  Future<void> _writeIndex(List<String> keys) async {
    final prefs = await _prefs();
    // SharedPreferences.setString は失敗時に `false` を返す（throw しない）。
    // 戻り値を無視すると失敗が成功扱いになり、legacy 移行側で legacy を
    // delete → 全アカウントインデックス永久消失、となる（Codex 指摘）。
    final ok = await prefs.setString(_accountListKey, jsonEncode(keys));
    if (!ok) {
      throw StateError('prefs.setString returned false for $_accountListKey');
    }
  }

  static void _reportOnce(String stage, Object error, StackTrace st) {
    final key = '$stage:${error.runtimeType}';
    if (!_reportedErrors.add(key)) return;
    Sentry.captureException(error, stackTrace: st);
  }

  /// macOS / iOS の Keychain アクセスで transient (再試行で読めるはず)
  /// と判定できる `PlatformException` を識別する (#531)。
  ///
  /// - `errSecInteractionNotAllowed` (-25308): Keychain ロック中 (画面解錠前)
  ///
  /// flutter_secure_storage は code をテキストで返すケースと数値文字列で
  /// 返すケースが両方ある (`Unexpected security result code` と整数の両方)。
  /// message にも `-25308` を含むため、両方の経路でマッチさせる。
  static bool _isKeychainTransient(PlatformException e) {
    const transientCodes = {'-25308'};
    if (transientCodes.contains(e.code)) return true;
    final msg = '${e.message ?? ''} ${e.details ?? ''}';
    for (final c in transientCodes) {
      if (msg.contains(c)) return true;
    }
    return false;
  }
}

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Web Push 用の ECDH P-256 鍵ペアと auth シークレットの生成・保管。
///
/// 鍵はアカウントごとに生成・保存され、リレーサーバー経由で受信した
/// Web Push ペイロードの復号に使用する（復号の実装は Stage 2）。
class PushKeyStore {
  static const _storage = FlutterSecureStorage();
  static const _prefix = 'capsicum_push_';

  /// 指定アカウントの鍵を取得する。未生成なら新規生成して保存する。
  static Future<PushKeys> getOrCreate(String accountStorageKey) async {
    final existing = await _load(accountStorageKey);
    if (existing != null) return existing;

    final keys = await _generate();
    await _save(accountStorageKey, keys);
    return keys;
  }

  /// リレーサーバーの subscription ID を保存する。
  static Future<void> saveRelayId(String accountStorageKey, int id) async {
    await _storage.write(
      key: '${_prefix}relay_id_$accountStorageKey',
      value: '$id',
    );
  }

  /// リレーサーバーの subscription ID を取得する。
  static Future<int?> getRelayId(String accountStorageKey) async {
    final v = await _storage.read(key: '${_prefix}relay_id_$accountStorageKey');
    return v != null ? int.tryParse(v) : null;
  }

  /// 指定アカウントの鍵・登録情報をすべて削除する。
  static Future<void> delete(String accountStorageKey) async {
    for (final suffix in ['p256dh', 'auth', 'private', 'relay_id']) {
      await _storage.delete(key: '$_prefix${suffix}_$accountStorageKey');
    }
  }

  static Future<PushKeys?> _load(String key) async {
    final p256dh = await _storage.read(key: '${_prefix}p256dh_$key');
    final auth = await _storage.read(key: '${_prefix}auth_$key');
    final privateKey = await _storage.read(key: '${_prefix}private_$key');
    if (p256dh == null || auth == null || privateKey == null) return null;
    return PushKeys(p256dh: p256dh, auth: auth, privateKeyBase64: privateKey);
  }

  static Future<PushKeys> _generate() async {
    final algorithm = Ecdh.p256(length: 32);
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();

    // Uncompressed point format: [0x04] || X (32 bytes) || Y (32 bytes)
    final uncompressed = Uint8List(65);
    uncompressed[0] = 0x04;
    uncompressed.setRange(1, 33, publicKey.x);
    uncompressed.setRange(33, 65, publicKey.y);
    final p256dh = base64Url.encode(uncompressed);

    // 16-byte random auth secret
    final random = Random.secure();
    final authBytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      authBytes[i] = random.nextInt(256);
    }
    final auth = base64Url.encode(authBytes);

    // Private key D value（復号に必要、Stage 2 で使用）
    final data = await keyPair.extract();
    final privateKeyBase64 = base64Url.encode(Uint8List.fromList(data.d));

    return PushKeys(
      p256dh: p256dh,
      auth: auth,
      privateKeyBase64: privateKeyBase64,
    );
  }

  static Future<void> _save(String key, PushKeys keys) async {
    await _storage.write(key: '${_prefix}p256dh_$key', value: keys.p256dh);
    await _storage.write(key: '${_prefix}auth_$key', value: keys.auth);
    await _storage.write(
      key: '${_prefix}private_$key',
      value: keys.privateKeyBase64,
    );
  }
}

/// アカウントに紐づく Web Push 鍵セット。
class PushKeys {
  /// Base64URL エンコードされた P-256 非圧縮公開鍵（65 バイト）。
  final String p256dh;

  /// Base64URL エンコードされた 16 バイト認証シークレット。
  final String auth;

  /// Base64URL エンコードされた秘密鍵 D 値（復号用、Stage 2）。
  final String privateKeyBase64;

  const PushKeys({
    required this.p256dh,
    required this.auth,
    required this.privateKeyBase64,
  });
}

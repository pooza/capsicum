import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

/// Web Push 用の ECDH P-256 鍵ペアと auth シークレットの生成・保管。
///
/// 鍵はアカウントごとに生成・保存され、リレーサーバー経由で受信した
/// Web Push ペイロードの復号に使用する（復号の実装は Stage 2）。
class PushKeyStore {
  /// iOS では Notification Service Extension (#336 Phase 3(b)) が復号に
  /// 使うため、Keychain を Runner / NSE 共通の Access Group に逃がす。
  /// Android の [AndroidOptions] は EncryptedSharedPreferences 既定で十分で、
  /// バックグラウンド isolate も同一プロセス内のため追加設定は不要。
  static const _iOSAccessGroup = 'group.jp.co.b-shock.capsicum';
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(groupId: _iOSAccessGroup),
  );
  static const _prefix = 'capsicum_push_';

  /// 指定アカウントの鍵を取得する。未生成なら新規生成して保存する。
  static Future<PushKeys> getOrCreate(String accountStorageKey) async {
    final existing = await _load(accountStorageKey);
    if (existing != null) return existing;

    final keys = _generate();
    await _save(accountStorageKey, keys);
    return keys;
  }

  /// 既存の鍵を読み出す。未生成なら null を返す（副作用なし）。
  /// unregister 経路のように「既存鍵が無ければスキップしたい」ケースで使う。
  static Future<PushKeys?> read(String accountStorageKey) async {
    return _load(accountStorageKey);
  }

  /// リレーサーバーの subscription ID を保存する。
  static Future<void> saveRelayId(String accountStorageKey, int id) async {
    await _storage.write(
      key: _key(_Slot.relayId, accountStorageKey),
      value: '$id',
    );
  }

  /// リレーサーバーの subscription ID を取得する。
  static Future<int?> getRelayId(String accountStorageKey) async {
    final v = await _storage.read(key: _key(_Slot.relayId, accountStorageKey));
    return v != null ? int.tryParse(v) : null;
  }

  /// Web Push サブスクリプションのエンドポイント URL を保存する。
  /// Misskey の unregister には endpoint が必須だが、再起動後はアダプター
  /// インスタンスが新規作成され in-memory の値が失われるため永続化する。
  static Future<void> saveEndpoint(
    String accountStorageKey,
    String endpoint,
  ) async {
    await _storage.write(
      key: _key(_Slot.endpoint, accountStorageKey),
      value: endpoint,
    );
  }

  /// 保存済みの Web Push エンドポイント URL を取得する。
  static Future<String?> getEndpoint(String accountStorageKey) async {
    return _storage.read(key: _key(_Slot.endpoint, accountStorageKey));
  }

  /// 指定アカウントの鍵・登録情報をすべて削除する。
  static Future<void> delete(String accountStorageKey) async {
    for (final slot in _Slot.values) {
      await _storage.delete(key: _key(slot, accountStorageKey));
    }
  }

  static String _key(_Slot slot, String accountStorageKey) =>
      '$_prefix${slot.fragment}_$accountStorageKey';

  /// 鍵セット（p256dh / auth / privateKey）の 1 JSON blob を読む。
  ///
  /// 旧来は 3 スロット個別 write だったため、書き換え中に並行した
  /// バックグラウンド isolate / iOS NSE が読むと新旧混成ロードで silent
  /// 復号失敗を起こしうるレースがあった。1 blob 化でアトミック化している。
  static Future<PushKeys?> _load(String key) async {
    final raw = await _storage.read(key: _key(_Slot.keyset, key));
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is Map &&
            json['p256dh'] is String &&
            json['auth'] is String &&
            json['priv'] is String) {
          return PushKeys(
            p256dh: json['p256dh'] as String,
            auth: json['auth'] as String,
            privateKeyBase64: json['priv'] as String,
          );
        }
      } catch (_) {
        // パース不能な値は壊れているので null 扱いで再生成を促す
      }
    }
    return null;
  }

  static PushKeys _generate() {
    final secureRandom = FortunaRandom();
    final seed = Uint8List(32);
    final dartRandom = Random.secure();
    for (var i = 0; i < 32; i++) {
      seed[i] = dartRandom.nextInt(256);
    }
    secureRandom.seed(KeyParameter(seed));

    // P-256 (secp256r1) 鍵ペア生成
    final keyGen = ECKeyGenerator()
      ..init(
        ParametersWithRandom(
          ECKeyGeneratorParameters(ECCurve_secp256r1()),
          secureRandom,
        ),
      );
    final pair = keyGen.generateKeyPair();
    final publicKey = pair.publicKey as ECPublicKey;
    final privateKey = pair.privateKey as ECPrivateKey;

    // Uncompressed point format: [0x04] || X (32 bytes) || Y (32 bytes)
    final uncompressed = publicKey.Q!.getEncoded(false);
    final p256dh = base64Url.encode(uncompressed);

    // 16-byte random auth secret
    final authBytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      authBytes[i] = dartRandom.nextInt(256);
    }
    final auth = base64Url.encode(authBytes);

    // Private key D value（復号に必要、Stage 2 で使用）
    final dBytes = _bigIntToBytes(privateKey.d!, 32);
    final privateKeyBase64 = base64Url.encode(dBytes);

    return PushKeys(
      p256dh: p256dh,
      auth: auth,
      privateKeyBase64: privateKeyBase64,
    );
  }

  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final hex = value.toRadixString(16).padLeft(length * 2, '0');
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  /// 鍵セットを 1 JSON blob として書く（レース回避のためアトミック）。
  static Future<void> _save(String key, PushKeys keys) async {
    final body = jsonEncode({
      'p256dh': keys.p256dh,
      'auth': keys.auth,
      'priv': keys.privateKeyBase64,
    });
    await _storage.write(key: _key(_Slot.keyset, key), value: body);
  }
}

/// 永続化する要素種別。enum に集約することで `delete()` 側の列挙忘れや
/// サフィックス文字列のタイポを排除する。
///
/// [keyset] は p256dh / auth / privateKey をまとめた JSON blob のスロット。
/// 旧版では各鍵を個別スロット (p256dh/auth/privateKey) に書き分けていたが、
/// 書き換え中の読み出しで新旧混成ロードが起きる race を避けるため統合した。
enum _Slot {
  keyset('keyset'),
  relayId('relay_id'),
  endpoint('endpoint');

  final String fragment;
  const _Slot(this.fragment);
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

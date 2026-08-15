import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../util/exception_scrub.dart';

/// Web Push 用の ECDH P-256 鍵ペアと auth シークレットの生成・保管。
///
/// 鍵はアカウントごとに生成・保存され、リレーサーバー経由で受信した
/// Web Push ペイロードの復号に使用する（復号の実装は Stage 2）。
class PushKeyStore {
  /// iOS の Notification Service Extension (#336 Phase 3(b)) と macOS の
  /// バックグラウンド経路で復号に使うため、Keychain を Runner / NSE 共通の
  /// Access Group に逃がす。macOS 側 entitlement (#397) と一致させる必要が
  /// あり、IOSOptions と MacOsOptions に同じ値を指定する。Android の
  /// [AndroidOptions] は EncryptedSharedPreferences 既定で十分で、
  /// バックグラウンド isolate も同一プロセス内のため追加設定は不要。
  ///
  /// `kSecAttrAccessGroup` は **TeamID + ドット + グループ名** の完全表記が
  /// 必須 (Apple Keychain Services Programming Guide)。bare 表記
  /// （`group.jp.co.b-shock.capsicum`）でも development 署名では通ることが
  /// あるが、distribution（TestFlight / App Store）署名ではエントリが
  /// entitlements に解決できず、書き込み・読み出しが silent に失敗する。
  /// `Y27AK8VF85` は Xcode project の `DEVELOPMENT_TEAM` と一致 (#373 候補 B)。
  /// NSE 側 [PushKeyReader.accessGroup] と同じ文字列を使うこと。
  ///
  /// [KeychainAccessibility.first_unlock]（= `kSecAttrAccessibleAfterFirstUnlock`）
  /// は再起動後の最初のアンロック以降であればロック中でも read/write 可能にする。
  /// 既定の `unlocked` だとバックグラウンド経路（NSE / トークン更新 / 通知到着等）が
  /// デバイスロック中に -25308 errSecInteractionNotAllowed で弾かれる (#385)。
  static const _appleAccessGroup = 'Y27AK8VF85.group.jp.co.b-shock.capsicum';
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      groupId: _appleAccessGroup,
      accessibility: KeychainAccessibility.first_unlock,
    ),
    mOptions: MacOsOptions(
      groupId: _appleAccessGroup,
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );
  static const _prefix = 'capsicum_push_';

  /// #385（iOS）/ #454（macOS）で `groupId` + `first_unlock` を入れる以前の鍵は
  /// `FlutterSecureStorage()` 既定、すなわち **groupId 無し + accessibility
  /// `unlocked`** で保存されている。flutter_secure_storage の readAll / delete は
  /// クエリに `kSecAttrAccessible` と `kSecAttrAccessGroup` を含めるため、現行
  /// [_storage]（group + first_unlock）からはそれら旧鍵が見えず・消せない。
  /// 旧鍵を列挙・削除するための per-call options (#656)。AccountStorage の同型
  /// 対応 (#643) と同じ手法。
  static const _legacyIosOptions = IOSOptions(
    accessibility: KeychainAccessibility.unlocked,
  );
  static const _legacyMacOptions = MacOsOptions(
    accessibility: KeychainAccessibility.unlocked,
  );

  /// v1.20 以前に書き込んだ鍵は旧 accessibility (kSecAttrAccessibleWhenUnlocked)
  /// + groupId 無しのまま。flutter_secure_storage は既存 item の attribute を
  /// 書き換えないため、起動時に一度だけ旧 options で read → delete し、現行
  /// [_storage]（group + first_unlock）で re-write して焼き直す。完了フラグを
  /// SharedPreferences に持って二度目以降はスキップ (#392 / #656)。
  ///
  /// `_v1` は旧 migration が `_storage`（group + first_unlock）の readAll で
  /// 列挙していたため旧鍵を取りこぼし、空振りでフラグだけ立てていた (#656)。
  /// 修正版を全端末で再実行させるため `_v2` に上げる。
  ///
  /// Android (EncryptedSharedPreferences) は accessibility / accessGroup 概念が
  /// ないため no-op に近い処理になるが、フラグを立てるためには走らせる。
  static const _migrationFlagKey = 'push_keystore_accessibility_migrated_v2';

  /// デバイストークン（アカウント非依存・デバイス単位）の保存キー。
  static const _deviceTokenKey = '${_prefix}device_token';

  static Future<void> migrateAccessibilityIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migrationFlagKey) ?? false) return;
    try {
      // 旧鍵 (groupId 無し + unlocked) を明示 options で列挙する。
      final all = await _storage.readAll(
        iOptions: _legacyIosOptions,
        mOptions: _legacyMacOptions,
      );
      for (final entry in all.entries) {
        // PushKeyStore 所有の鍵のみ焼き直す。旧鍵は groupId 無しの partition を
        // AccountStorage（secret_ / client_creds_ 等）と共有しうるため、prefix で
        // 自分の item に限定して他用途を触らない。
        if (!entry.key.startsWith(_prefix)) continue;
        // 旧 options を明示して delete（現行 options の delete は旧鍵に
        // マッチせず no-op）→ 引数なし = 現行 _storage（group + first_unlock）で
        // 書き直す。group partition が変わるため -25299 衝突は起きない。
        await _storage.delete(
          key: entry.key,
          iOptions: _legacyIosOptions,
          mOptions: _legacyMacOptions,
        );
        try {
          await _storage.write(key: entry.key, value: entry.value);
        } on PlatformException {
          // delete 成功直後に write が transient error（ロック中 -25308 等）で
          // 落ちると鍵が Keychain からも in-memory からも失われ、次回 readAll
          // にも現れず push 鍵を喪失する。旧 options で書き戻して保全してから
          // rethrow し、flag を立てず次回起動で再試行させる。push 鍵は
          // getOrCreate で再生成可能だが、再生成はリレー再登録（新 p256dh）を
          // 要し push 不達の窓を作るため、できるだけ保全する。
          await _storage.write(
            key: entry.key,
            value: entry.value,
            iOptions: _legacyIosOptions,
            mOptions: _legacyMacOptions,
          );
          rethrow;
        }
      }
      await prefs.setBool(_migrationFlagKey, true);
    } on PlatformException catch (e) {
      // ロック中 (-25308) 等で readAll / write が失敗しても起動は止めない。
      // flag を立てないので次回起動で再試行される。
      debugLogException('capsicum: push key accessibility migration failed', e);
    }
  }

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

  /// 直近の登録に使ったデバイストークン（APNs / FCM のトークン、Windows は
  /// WNS の Channel URI）を保存する (#937)。
  ///
  /// **アカウント単位ではなくデバイス単位の値**なので [_Slot] には入れず固定
  /// キーで持つ。[delete] は [_Slot] を列挙するため、1 アカウントのログアウト
  /// で巻き添えに消えることがない。
  static Future<void> saveDeviceToken(String token) async {
    await _storage.write(key: _deviceTokenKey, value: token);
  }

  /// 直近の登録に使ったデバイストークンを取得する。未保存なら null。
  static Future<String?> getDeviceToken() async {
    return _storage.read(key: _deviceTokenKey);
  }

  /// 保存済みデバイストークンを消す。デバイス全体の登録を畳むとき
  /// （token rotation の掃除など）に、次回起動で誤検知しないよう合わせて呼ぶ。
  static Future<void> deleteDeviceToken() async {
    await _storage.delete(key: _deviceTokenKey);
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

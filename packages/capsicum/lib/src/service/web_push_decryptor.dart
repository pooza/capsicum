import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// RFC 8291 (Web Push Encryption) を復号する。
///
/// 対応する暗号化形式:
/// - aes128gcm (RFC 8291 + RFC 8188): ペイロード本体に salt / keyid / rs が
///   埋め込まれるため body 単体で復号できる。capsicum-relay の転送形式で
///   必要なのはこの形式のみ。
/// - aesgcm (legacy): 未対応。復号に `Encryption` / `Crypto-Key` HTTP ヘッダが
///   必要。Mastodon には `subscription[standard]=true` を明示しており (#336
///   準備コミット)、Misskey も既定で aes128gcm のため実運用では aesgcm が
///   出現しない想定。必要になった時点で拡張する。
class WebPushDecryptor {
  /// Web Push ペイロード (aes128gcm) を復号する。
  ///
  /// [body] は RFC 8188 形式のバイト列
  /// (salt(16) || rs(4) || idlen(1) || keyid(idlen) || ciphertext)。
  /// [uaPrivateKeyD] は受信者の P-256 秘密鍵 D 値 (32 バイト)。
  /// [uaPublicKey] は受信者の P-256 公開鍵 (非圧縮 65 バイト)。
  /// [authSecret] は Web Push 登録時に交換した 16 バイト認証秘密。
  static Uint8List decryptAes128gcm({
    required Uint8List body,
    required Uint8List uaPrivateKeyD,
    required Uint8List uaPublicKey,
    required Uint8List authSecret,
  }) {
    if (body.length < 21) {
      throw const FormatException('payload too short');
    }
    final salt = Uint8List.sublistView(body, 0, 16);
    final rs = ByteData.sublistView(body, 16, 20).getUint32(0, Endian.big);
    if (rs == 0) {
      throw const FormatException('record size must be non-zero');
    }
    final idlen = body[20];
    if (body.length < 21 + idlen) {
      throw const FormatException('payload truncated before keyid');
    }
    final keyid = Uint8List.sublistView(body, 21, 21 + idlen);
    final ciphertext = Uint8List.sublistView(body, 21 + idlen);

    if (idlen != 65 || keyid[0] != 0x04) {
      throw const FormatException(
        'invalid keyid: expected uncompressed P-256 public key',
      );
    }
    final asPublic = keyid;

    final ecdhSecret = _ecdhP256(uaPrivateKeyD, asPublic);

    // RFC 8291 §3.4: IKM = HKDF(auth_secret, ecdh_secret, key_info, 32)
    final ikm = _hkdf(
      ikm: ecdhSecret,
      salt: authSecret,
      info: _concat([
        utf8.encode('WebPush: info'),
        Uint8List.fromList([0]),
        uaPublicKey,
        asPublic,
      ]),
      length: 32,
    );

    // RFC 8188 §2.2: CEK / NONCE = HKDF(IKM, salt, label, len)
    final cek = _hkdf(
      ikm: ikm,
      salt: salt,
      info: _concat([
        utf8.encode('Content-Encoding: aes128gcm'),
        Uint8List.fromList([0]),
      ]),
      length: 16,
    );
    final nonce = _hkdf(
      ikm: ikm,
      salt: salt,
      info: _concat([
        utf8.encode('Content-Encoding: nonce'),
        Uint8List.fromList([0]),
      ]),
      length: 12,
    );

    final plaintextWithPadding = _aesGcmDecrypt(ciphertext, cek, nonce);
    return _stripPadding(plaintextWithPadding);
  }

  static Uint8List _ecdhP256(Uint8List privateKeyD, Uint8List publicKey) {
    final params = ECCurve_secp256r1();
    final priv = ECPrivateKey(_bytesToBigInt(privateKeyD), params);
    final q = params.curve.decodePoint(publicKey);
    if (q == null) {
      throw const FormatException('invalid P-256 public key');
    }
    final pub = ECPublicKey(q, params);
    final agreement = ECDHBasicAgreement()..init(priv);
    final shared = agreement.calculateAgreement(pub);
    return _bigIntToBytes(shared, 32);
  }

  static Uint8List _hkdf({
    required Uint8List ikm,
    required Uint8List salt,
    required Uint8List info,
    required int length,
  }) {
    final hkdf = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(ikm, length, salt, info));
    final out = Uint8List(length);
    hkdf.deriveKey(Uint8List(0), 0, out, 0);
    return out;
  }

  static Uint8List _aesGcmDecrypt(
    Uint8List ciphertext,
    Uint8List key,
    Uint8List nonce,
  ) {
    final cipher = GCMBlockCipher(
      AESEngine(),
    )..init(false, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    final out = Uint8List(cipher.getOutputSize(ciphertext.length));
    final n = cipher.processBytes(ciphertext, 0, ciphertext.length, out, 0);
    final finalLen = cipher.doFinal(out, n);
    return Uint8List.sublistView(out, 0, n + finalLen);
  }

  /// RFC 8188 §2: 単一レコードの末尾は 0x02 デリミタ + 0x00 パディング。
  /// ここでは単一レコード前提（record_size を超える multi-record は非対応）。
  static Uint8List _stripPadding(Uint8List bytes) {
    var i = bytes.length - 1;
    while (i >= 0 && bytes[i] == 0x00) {
      i--;
    }
    if (i < 0 || bytes[i] != 0x02) {
      throw const FormatException(
        'missing aes128gcm last-record delimiter (0x02)',
      );
    }
    return Uint8List.fromList(bytes.sublist(0, i));
  }

  static Uint8List _concat(List<List<int>> parts) {
    final total = parts.fold<int>(0, (acc, p) => acc + p.length);
    final out = Uint8List(total);
    var off = 0;
    for (final p in parts) {
      out.setRange(off, off + p.length, p);
      off += p.length;
    }
    return out;
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final out = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    return out;
  }
}

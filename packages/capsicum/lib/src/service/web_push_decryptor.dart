import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// RFC 8291 (Web Push Encryption) を復号する。
///
/// 対応する暗号化形式:
/// - aes128gcm (RFC 8291 + RFC 8188): ペイロード本体に salt / keyid / rs が
///   埋め込まれるため body 単体で復号できる。Mastodon（`standard=true` を明示・
///   #336）と Misskey はこちら。
/// - aesgcm (draft-ietf-webpush-encryption-04 + draft-ietf-httpbis-encryption-
///   encoding-03): 復号に `Crypto-Key`（`dh=`）と `Encryption`（`salt=`）の
///   ヘッダが要る。relay はこの 2 つを `crypto_key` / `encryption` として転送
///   している。⚠ **Akkoma（Pleroma 系）はこちらでしか送らない**（#1390・
///   2026-11-18 に Akkoma 3.20.1 で実測）。古い Mastodon（4.3 以前）もこちら。
///
/// ⚠ 2026-11-18 まで aesgcm は「対応しない」としていた。線引きを変えたのは
/// Akkoma のプッシュ通知（#1390）のため。
class WebPushDecryptor {
  /// [encoding] で振り分けて復号する。呼び出し側はこれだけを呼ぶ。
  ///
  /// [cryptoKey] / [encryption] は aesgcm のときだけ要る（relay の
  /// `crypto_key` / `encryption`）。未対応の [encoding] や、aesgcm でヘッダが
  /// 欠けているときは [FormatException]。
  static Uint8List decrypt({
    required String encoding,
    required Uint8List body,
    required Uint8List uaPrivateKeyD,
    required Uint8List uaPublicKey,
    required Uint8List authSecret,
    String? cryptoKey,
    String? encryption,
  }) {
    switch (encoding) {
      case 'aes128gcm':
        return decryptAes128gcm(
          body: body,
          uaPrivateKeyD: uaPrivateKeyD,
          uaPublicKey: uaPublicKey,
          authSecret: authSecret,
        );
      case 'aesgcm':
        if (cryptoKey == null || encryption == null) {
          throw const FormatException('aesgcm needs Crypto-Key and Encryption');
        }
        return decryptAesgcm(
          body: body,
          cryptoKey: cryptoKey,
          encryption: encryption,
          uaPrivateKeyD: uaPrivateKeyD,
          uaPublicKey: uaPublicKey,
          authSecret: authSecret,
        );
      default:
        throw const FormatException('unsupported content encoding');
    }
  }

  /// 復号できる `Content-Encoding` か。呼び出し側の「試すかどうか」の判定に使う。
  static bool supports(String? encoding) =>
      encoding == 'aes128gcm' || encoding == 'aesgcm';

  /// Web Push ペイロード (aesgcm・旧方式) を復号する。
  ///
  /// [cryptoKey] は `Crypto-Key` ヘッダの値（`dh=<送信側の公開鍵>` を含む。
  /// Akkoma は `dh=…;p256ecdsa=…` の形で送る）。[encryption] は `Encryption`
  /// ヘッダの値（`salt=<16 バイト>`、任意で `rs=`）。
  ///
  /// 単一レコードだけを扱う（Web Push の本文は 4KB 以下で、既定の rs 4096 に
  /// 収まる）。
  static Uint8List decryptAesgcm({
    required Uint8List body,
    required String cryptoKey,
    required String encryption,
    required Uint8List uaPrivateKeyD,
    required Uint8List uaPublicKey,
    required Uint8List authSecret,
  }) {
    final dh = _headerParam(cryptoKey, 'dh');
    final saltParam = _headerParam(encryption, 'salt');
    if (dh == null || saltParam == null) {
      throw const FormatException('aesgcm header is missing dh or salt');
    }
    final asPublic = _decodeB64Url(dh);
    final salt = _decodeB64Url(saltParam);
    if (asPublic.length != 65 || asPublic[0] != 0x04) {
      throw const FormatException(
        'invalid dh: expected uncompressed P-256 public key',
      );
    }
    if (salt.length != 16) {
      throw const FormatException('invalid salt length');
    }
    final rsParam = _headerParam(encryption, 'rs');
    final rs = rsParam == null ? 4096 : int.tryParse(rsParam);
    if (rs == null || rs <= 2) {
      throw const FormatException('invalid record size');
    }
    // 1 レコードは rs バイトの平文 + 16 バイトのタグ。
    if (body.length > rs + 16) {
      throw const FormatException('multi-record aesgcm is not supported');
    }

    final ecdhSecret = _ecdhP256(uaPrivateKeyD, asPublic);

    // draft-ietf-webpush-encryption-04 §3.3: auth_secret を salt にした HKDF。
    final ikm = _hkdf(
      ikm: ecdhSecret,
      salt: authSecret,
      info: _concat([
        utf8.encode('Content-Encoding: auth'),
        Uint8List.fromList([0]),
      ]),
      length: 32,
    );

    // context = "P-256" || 0x00 || len(ua) || ua || len(as) || as（長さは 2 バイト BE）
    final context = _concat([
      utf8.encode('P-256'),
      Uint8List.fromList([0]),
      _uint16(uaPublicKey.length),
      uaPublicKey,
      _uint16(asPublic.length),
      asPublic,
    ]);
    final cek = _hkdf(
      ikm: ikm,
      salt: salt,
      info: _concat([
        utf8.encode('Content-Encoding: aesgcm'),
        Uint8List.fromList([0]),
        context,
      ]),
      length: 16,
    );
    final nonce = _hkdf(
      ikm: ikm,
      salt: salt,
      info: _concat([
        utf8.encode('Content-Encoding: nonce'),
        Uint8List.fromList([0]),
        context,
      ]),
      length: 12,
    );

    final padded = _aesGcmDecrypt(body, cek, nonce);
    return _stripAesgcmPadding(padded);
  }

  /// aesgcm のパディング: 先頭 2 バイト（BE）がパディング長で、その分の 0x00 が
  /// 続いてから平文。
  static Uint8List _stripAesgcmPadding(Uint8List bytes) {
    if (bytes.length < 2) {
      throw const FormatException('aesgcm record too short');
    }
    final padLength = (bytes[0] << 8) | bytes[1];
    final start = 2 + padLength;
    if (start > bytes.length) {
      throw const FormatException('aesgcm padding exceeds record');
    }
    for (var i = 2; i < start; i++) {
      if (bytes[i] != 0x00) {
        throw const FormatException('aesgcm padding is not zero');
      }
    }
    return Uint8List.fromList(bytes.sublist(start));
  }

  /// `Crypto-Key: dh=…;p256ecdsa=…` / `Encryption: salt=…;rs=…` から 1 つ取る。
  ///
  /// ⚠ 値はカンマ区切りで複数並ぶことがあり（`keyid=a;dh=…,p256ecdsa=…`）、
  /// 区切りは `;` と `,` の両方を見る。引用符で囲まれていても外す。
  static String? _headerParam(String header, String name) {
    for (final part in header.split(RegExp('[;,]'))) {
      final eq = part.indexOf('=');
      if (eq < 0) continue;
      if (part.substring(0, eq).trim().toLowerCase() != name) continue;
      var value = part.substring(eq + 1).trim();
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      return value;
    }
    return null;
  }

  static Uint8List _decodeB64Url(String value) =>
      base64Url.decode(base64Url.normalize(value.replaceAll('=', '')));

  static Uint8List _uint16(int value) =>
      Uint8List.fromList([(value >> 8) & 0xff, value & 0xff]);

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

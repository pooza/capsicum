import 'dart:convert';
import 'dart:typed_data';

import 'package:capsicum/src/service/web_push_decryptor.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b64url(String s) {
  return base64Url.decode(base64Url.normalize(s));
}

void main() {
  group('WebPushDecryptor', () {
    test('RFC 8291 Appendix A: aes128gcm 既知ベクタを復号できる', () {
      // https://datatracker.ietf.org/doc/html/rfc8291#appendix-A
      final uaPrivate = _b64url('q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94');
      final uaPublic = _b64url(
        'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyP'
        'js7Vd8pZGH6SRpkNtoIAiw4',
      );
      final authSecret = _b64url('BTBZMqHH6r4Tts7J_aSIgg');
      final body = _b64url(
        'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml'
        'mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT'
        'pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN',
      );

      final plaintext = WebPushDecryptor.decryptAes128gcm(
        body: body,
        uaPrivateKeyD: uaPrivate,
        uaPublicKey: uaPublic,
        authSecret: authSecret,
      );

      expect(
        utf8.decode(plaintext),
        'When I grow up, I want to be a watermelon',
      );
    });

    test('改竄された ciphertext は例外で失敗する', () {
      final uaPrivate = _b64url('q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94');
      final uaPublic = _b64url(
        'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyP'
        'js7Vd8pZGH6SRpkNtoIAiw4',
      );
      final authSecret = _b64url('BTBZMqHH6r4Tts7J_aSIgg');
      final body = _b64url(
        'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml'
        'mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT'
        'pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN',
      );
      // ciphertext の 1 バイトを反転
      body[body.length - 1] ^= 0x01;

      expect(
        () => WebPushDecryptor.decryptAes128gcm(
          body: body,
          uaPrivateKeyD: uaPrivate,
          uaPublicKey: uaPublic,
          authSecret: authSecret,
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('auth_secret が違うと復号に失敗する', () {
      final uaPrivate = _b64url('q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94');
      final uaPublic = _b64url(
        'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyP'
        'js7Vd8pZGH6SRpkNtoIAiw4',
      );
      final wrongAuth = Uint8List(16); // 全 0 の誤った auth_secret
      final body = _b64url(
        'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml'
        'mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT'
        'pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN',
      );

      expect(
        () => WebPushDecryptor.decryptAes128gcm(
          body: body,
          uaPrivateKeyD: uaPrivate,
          uaPublicKey: uaPublic,
          authSecret: wrongAuth,
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('ヘッダが短すぎるペイロードは FormatException', () {
      expect(
        () => WebPushDecryptor.decryptAes128gcm(
          body: Uint8List.fromList([0, 1, 2]),
          uaPrivateKeyD: Uint8List(32),
          uaPublicKey: Uint8List(65)..[0] = 0x04,
          authSecret: Uint8List(16),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // #1390: Akkoma（Pleroma 系）は aesgcm でしか送らない（2026-11-18 に
  // Akkoma 3.20.1 で実測）。ベクタは参照実装の http_ece（Python・1.2.1）で
  // 作った。鍵はこのテストのためだけに生成した使い捨て。
  //
  // ⚠ Akkoma の実物（`Crypto-Key: dh=…;p256ecdsa=…` / `Encryption: salt=…`・
  // Content-Type なし）は手元で照合して通ったが、平文に access_token が入る
  // のでここには置かない。
  group('WebPushDecryptor aesgcm', () {
    final uaPrivate = _b64url('dHFZR6GbgdtEXz1ihmtb3XKIpesGkP8hPNzgBMqBXsM');
    final uaPublic = _b64url(
      'BOaP7Rqa5UYJXUzicD8BY_GjojTEtk4sdIT9wQiherhu4U0LqyEfd_IixIALdqFVo2li'
      'i3Pmww7yx94irmy9efQ',
    );
    final authSecret = _b64url('AAECAwQFBgcICQoLDA0ODw');
    const dh =
        'BFClYpzh35kPLsutfMjcGlJFa0gCt7IxYsROs3W0A1ExNHkdNpFeXgKlDX2xisTpxBhU'
        'mR8LACHvrTXxXbH58mQ';
    const salt = 'ZGVmZ2hpamtsbW5vcHFycw';
    // Akkoma と同じ並び（dh の後ろに p256ecdsa）。
    const cryptoKey = 'dh=$dh;p256ecdsa=BAnWLIQt';
    const encryption = 'salt=$salt';
    Uint8List body() => _b64url(
      'fz9tMXkMRs-N59ij9_mlUoFVeQZpAgvP0uuGE8ejB1pzRGl7aC7JFcK9x55QAVkmBjF8'
      '8g2t6EQOUD4oOWFacKPVMfluJAuf-3HaauxS4B8uQutVxcUr2yHMnnxSFfgEni1HLEBu'
      '70m8OIm6tK39NTtU6qtbl7rbc5Lh5f4ZQfpb7GayFi-C8baShMsj4r8Dye9w6RcpcKHg'
      'M9yuPDLdmJdskVIjZJyI2nyNlR5VrY8i0DTpnNevxOuXyl6_uvS27UqaqiBuMZY',
    );
    const expected =
        '{"title": "capsicumtest2 さんからのメンション", '
        '"body": "@capsicumtest #1390 の確かめ", '
        '"notification_type": "mention", "notification_id": 68, '
        '"preferred_locale": "ja"}';

    Uint8List decrypt({
      Uint8List? payload,
      String? ck = cryptoKey,
      String? enc = encryption,
      Uint8List? auth,
      String encoding = 'aesgcm',
    }) => WebPushDecryptor.decrypt(
      encoding: encoding,
      body: payload ?? body(),
      uaPrivateKeyD: uaPrivate,
      uaPublicKey: uaPublic,
      authSecret: auth ?? authSecret,
      cryptoKey: ck,
      encryption: enc,
    );

    test('参照実装（http_ece）のベクタを復号できる', () {
      expect(utf8.decode(decrypt()), expected);
    });

    test('decryptAesgcm を直接呼んでも同じ', () {
      final plain = WebPushDecryptor.decryptAesgcm(
        body: body(),
        cryptoKey: cryptoKey,
        encryption: encryption,
        uaPrivateKeyD: uaPrivate,
        uaPublicKey: uaPublic,
        authSecret: authSecret,
      );
      expect(utf8.decode(plain), expected);
    });

    test('ヘッダの書き方の揺れ（keyid が先・カンマ区切り・引用符・rs）を読める', () {
      final plain = decrypt(
        ck: 'keyid=p256dh;dh="$dh",p256ecdsa=BAnWLIQt',
        enc: 'keyid=p256dh;salt="$salt";rs=4096',
      );
      expect(utf8.decode(plain), expected);
    });

    test('改竄された ciphertext は例外で失敗する', () {
      final tampered = body();
      tampered[tampered.length - 1] ^= 0x01;
      expect(() => decrypt(payload: tampered), throwsA(isA<Exception>()));
    });

    test('auth_secret が違えば失敗する', () {
      final wrongAuth = Uint8List.fromList(authSecret)..[0] ^= 0xff;
      expect(() => decrypt(auth: wrongAuth), throwsA(isA<Exception>()));
    });

    test('Crypto-Key / Encryption が欠けていれば FormatException', () {
      expect(() => decrypt(ck: null), throwsA(isA<FormatException>()));
      expect(() => decrypt(enc: null), throwsA(isA<FormatException>()));
      expect(
        () => decrypt(ck: 'p256ecdsa=BAnWLIQt'),
        throwsA(isA<FormatException>()),
      );
      expect(() => decrypt(enc: 'rs=4096'), throwsA(isA<FormatException>()));
    });

    test('rs を超える長さ（複数レコード）は FormatException', () {
      expect(
        () => decrypt(enc: 'salt=$salt;rs=16'),
        throwsA(isA<FormatException>()),
      );
    });

    test('未対応の encoding は FormatException', () {
      expect(() => decrypt(encoding: 'gzip'), throwsA(isA<FormatException>()));
    });

    test('supports は aes128gcm と aesgcm だけ', () {
      expect(WebPushDecryptor.supports('aes128gcm'), isTrue);
      expect(WebPushDecryptor.supports('aesgcm'), isTrue);
      expect(WebPushDecryptor.supports(null), isFalse);
      expect(WebPushDecryptor.supports(''), isFalse);
      expect(WebPushDecryptor.supports('gzip'), isFalse);
    });
  });
}

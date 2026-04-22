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
}

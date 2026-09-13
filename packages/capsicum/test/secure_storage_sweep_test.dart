import 'dart:async';

import 'package:capsicum/src/constants.dart';
import 'package:capsicum/src/platform/platform_info.dart';
import 'package:capsicum/src/service/secret_service_probe.dart';
import 'package:capsicum/src/service/secure_storage_health.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1117-C: secure storage の案内を「1 周」の単位で上げ下げする。
///
/// ⚠⚠ **以前は「後から書いたほうが勝つ」だった。**復元は全アカウントを並べて
/// 回すので、読めないアカウントが残っているのに**後続の 1 件が成功すると案内が
/// 消えていた**。原因（キーリング）に辿れる唯一の手掛かりなので消してはいけない。
void main() {
  setUp(SecureStorageHealth.resetForTest);
  tearDown(SecureStorageHealth.resetForTest);

  TimeoutException readTimeout() => TimeoutException(
    'secure storage read timed out',
    kSecureStorageReadTimeout,
  );

  group('案内の上げ下げ', () {
    test('読めなければ立つ', () {
      SecureStorageHealth.markUnavailable(readTimeout());

      expect(SecureStorageHealth.unavailable, isTrue);
    });

    test('1 件も落ちていない周で読めたら下りる', () {
      SecureStorageHealth.markUnavailable(readTimeout());
      SecureStorageHealth.beginSweep();

      SecureStorageHealth.markRecovered();

      expect(SecureStorageHealth.unavailable, isFalse);
    });

    // ⚠⚠ ここが #1117-C の本題。
    test('⚠⚠ 同じ周で 1 件でも落ちていれば、後続の成功では下りない', () {
      SecureStorageHealth.beginSweep();

      SecureStorageHealth.markUnavailable(readTimeout()); // アカウント 1
      SecureStorageHealth.markRecovered(); // アカウント 2 は読めた

      expect(
        SecureStorageHealth.unavailable,
        isTrue,
        reason: '読めないアカウントが残っているのに案内が消えると、原因に辿れない',
      );
    });

    test('⚠ 解錠できなかった（refused）も同じ周の失敗として数える', () {
      SecureStorageHealth.beginSweep();

      SecureStorageHealth.markRefused(StateError('locked'));
      SecureStorageHealth.markRecovered();

      expect(SecureStorageHealth.unavailable, isTrue);
    });

    test('次の周に入れば下りられる（復旧を妨げない）', () {
      SecureStorageHealth.beginSweep();
      SecureStorageHealth.markUnavailable(readTimeout());
      SecureStorageHealth.markRecovered();
      expect(SecureStorageHealth.unavailable, isTrue);

      // 「今すぐ再試行」等で次の周が始まった。
      SecureStorageHealth.beginSweep();
      SecureStorageHealth.markRecovered();

      expect(SecureStorageHealth.unavailable, isFalse);
    });
  });

  group('触って固まったことを覚える', () {
    setUp(() {
      SecretServiceProbe.resetForTest();
      // ⚠ Linux のふりをする。これが無いと markUnresponsive の分岐を一度も
      // 踏まない（手元は macOS）。
      debugSecretServiceOverride = true;
    });
    tearDown(() {
      SecretServiceProbe.resetForTest();
      debugSecretServiceOverride = null;
    });

    // ⚠ Secret Service を使わない OS では覚える相手が居ない（常に「応答する」）。
    test('⚠ 非 Secret Service の OS では常に応答する扱い', () async {
      debugSecretServiceOverride = false;

      SecretServiceProbe.markUnresponsive();

      expect(await SecretServiceProbe.isResponsive(), isTrue);
    });

    // ⚠⚠ **確認が true でも、その後の読み書きは固まりうる。**覚えないと後続の
    // アカウントが 1 件ごとに 5 秒払う。
    test('⚠⚠ 応答すると確かめた後でも、固まったら次からは触らない', () async {
      SecretServiceProbe.debugProbeOverride = () async => true;
      expect(await SecretServiceProbe.isResponsive(), isTrue);

      SecretServiceProbe.markUnresponsive();

      // ⚠ override は「聞き直したら true」を返すままにしておく。それでも
      // false が返る＝覚えた結果が効いている。
      expect(await SecretServiceProbe.isResponsive(), isFalse);
    });

    test('⚠ 覚えた false は次の周の頭で捨てる（復旧できる）', () async {
      SecretServiceProbe.debugProbeOverride = () async => true;
      await SecretServiceProbe.isResponsive();
      SecretServiceProbe.markUnresponsive();
      expect(await SecretServiceProbe.isResponsive(), isFalse);

      SecretServiceProbe.forgetUnresponsive();

      expect(await SecretServiceProbe.isResponsive(), isTrue);
    });
  });
}

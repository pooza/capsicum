import 'dart:async';
import 'dart:io';

import 'package:capsicum/src/platform/platform_info.dart';
import 'package:capsicum/src/service/secret_service_probe.dart';
import 'package:capsicum/src/service/secure_storage_gate.dart';
import 'package:capsicum/src/service/secure_storage_health.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1144: secure storage の打ち切りを、どの操作・どの店のものか分かる形で記録する。
///
/// ⚠ 以前は stage が `probe` / `read` の 2 値で、**削除中のタイムアウトが
/// `stage=read` として上がっていた**。さらに `PushKeyStore` / `DeviceInstallId`
/// の打ち切りは、案内カードにも Sentry にも出ていなかった。
void main() {
  group('stageOf', () {
    test('触る前に諦めた → probe', () {
      expect(
        SecureStorageHealth.stageOf(
          TimeoutException(SecureStorageHealth.probeSkipMessage),
        ),
        'probe',
      );
    });

    test('⚠ 触った操作の名前がそのまま stage になる（delete が read に化けない）', () {
      for (final op in ['read', 'write', 'delete', 'readAll', 'containsKey']) {
        expect(
          SecureStorageHealth.stageOf(
            TimeoutException('secure storage $op timed out'),
          ),
          op,
        );
      }
    });

    test('知らない形は read（以前と同じ）', () {
      expect(SecureStorageHealth.stageOf(TimeoutException(null)), 'read');
    });
  });

  group('ReportingSecureStorageGate', () {
    setUp(() {
      SecureStorageHealth.resetForTest();
      SecretServiceProbe.resetForTest();
      debugSecretServiceOverride = true;
      // 触る前の疎通確認で「応答しない」＝関所がその場で打ち切る。
      SecretServiceProbe.debugProbeOverride = () async => false;
    });
    tearDown(() {
      SecureStorageHealth.resetForTest();
      SecretServiceProbe.resetForTest();
      debugSecretServiceOverride = null;
    });

    test('⚠⚠ 打ち切りが案内の旗を立てる（以前は PushKeyStore の経路で立たなかった）', () async {
      const gate = ReportingSecureStorageGate(
        FlutterSecureStorage(),
        phase: 'push_key',
      );

      await expectLater(
        gate.delete(key: 'capsicum_push_keyset_x'),
        throwsA(isA<TimeoutException>()),
        reason: '記録しても例外は呼び出し側へ返す（握らない）',
      );
      expect(SecureStorageHealth.unavailable, isTrue);
    });

    test('⚠ PushKeyStore / DeviceInstallId は記録する関所を持つ', () {
      // 素の関所へ戻すと、上のテストは通ったまま記録だけが消える（委譲の検査）。
      for (final path in const [
        'lib/src/service/push_key_store.dart',
        'lib/src/service/device_install_id.dart',
      ]) {
        expect(
          File(path).readAsStringSync(),
          contains('_gate = ReportingSecureStorageGate('),
          reason: path,
        );
      }
    });

    test('素の関所は記録しない（AccountStorage は自分で記録する）', () async {
      const gate = SecureStorageGate(FlutterSecureStorage());

      await expectLater(
        gate.delete(key: 'x'),
        throwsA(isA<TimeoutException>()),
      );
      expect(SecureStorageHealth.unavailable, isFalse);
    });
  });
}

import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/platform/platform_info.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/service/account_storage.dart';
import 'package:capsicum/src/service/secret_service_probe.dart';
import 'package:capsicum/src/service/secure_storage_health.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1386: ロックされたキーリングで、OS のロック解除の画面が約 60 秒ごとに
/// 出続けた。
///
/// オフラインのアカウントの自動の再試行（背景ループ・前面への復帰）が、
/// そのたびにトークンを読みに行き、libsecret が解除の画面を出していた。
/// Cancel しても次の再試行でまた出る。
///
/// 直し方: **自動の経路は、読む前にロックを確かめ（解除の画面を出さない
/// D-Bus の問い合わせ）、ロック中なら読まない。**利用者が押した再試行は
/// 今どおり読む（解除の画面を出す）。
class _MockStorage extends Mock implements AccountStorage {}

void main() {
  const key = AccountKey(
    type: BackendType.mastodon,
    host: 'mstdn.example',
    username: 'alice',
  );
  final keyStr = key.toStorageKey();

  late _MockStorage storage;
  late ProviderContainer container;
  var locked = true;

  setUp(() async {
    SecureStorageHealth.resetForTest();
    SecretServiceProbe.resetForTest();
    debugSecretServiceOverride = true;
    SecretServiceProbe.debugProbeOverride = () async => true;
    locked = true;
    SecretServiceProbe.debugLockedOverride = () async => locked;

    storage = _MockStorage();
    when(() => storage.getAccountKeys()).thenAnswer((_) async => [keyStr]);
    // 読めない（ロック中に Cancel された）ので、オフラインで保持される。
    when(
      () => storage.getSecrets(keyStr),
    ).thenThrow(const TransientSecretUnavailableException('keyring locked'));

    container = ProviderContainer(
      overrides: [accountStorageProvider.overrideWithValue(storage)],
    );
    await container.read(accountManagerProvider.notifier).restoreSessions();
    expect(
      container.read(accountManagerProvider).offlineAccounts.map((o) => o.key),
      [key],
      reason: '前提: オフラインで保持されている',
    );
    clearInteractions(storage);
  });

  tearDown(() {
    container.dispose();
    SecureStorageHealth.resetForTest();
    SecretServiceProbe.resetForTest();
    debugSecretServiceOverride = null;
  });

  test('自動の再試行は、ロック中なら読みに行かない（解除の画面を出さない）', () async {
    final ran = await container
        .read(accountManagerProvider.notifier)
        .retryOfflineRestores();

    expect(ran, isTrue, reason: '再試行の 1 周としては走った（背景ループの数え方）');
    verifyNever(() => storage.getSecrets(any()));
    expect(SecureStorageHealth.unavailable, isTrue);
    expect(SecureStorageHealth.locked, isTrue, reason: '案内をロック中の文面にする');
    expect(
      container.read(accountManagerProvider).offlineAccounts.single.retrying,
      isFalse,
      reason: '⚠ 読まずに返しても「再試行中…」のままにしない（inori の実機で踏んだ）',
    );
  });

  test('前面に戻ったときの再試行も、ロック中なら読みに行かない', () async {
    container
        .read(accountManagerProvider.notifier)
        .refreshOfflineRestoresOnResume();
    await pumpEventQueue();

    verifyNever(() => storage.getSecrets(any()));
  });

  test('利用者が押した再試行は、ロック中でも読みに行く（解除の画面を出す）', () async {
    await container
        .read(accountManagerProvider.notifier)
        .retryOfflineRestores(userInitiated: true);

    verify(() => storage.getSecrets(keyStr)).called(1);
  });

  test('ロックが解けていれば、自動の再試行も読みに行き、ロック中の案内を下ろす', () async {
    await container
        .read(accountManagerProvider.notifier)
        .retryOfflineRestores();
    expect(SecureStorageHealth.locked, isTrue);

    locked = false;
    await container
        .read(accountManagerProvider.notifier)
        .retryOfflineRestores();

    verify(() => storage.getSecrets(keyStr)).called(1);
    expect(
      SecureStorageHealth.locked,
      isFalse,
      reason: '解けているのに「ロックされています」と言い続けない',
    );
  });

  test('ロックを確かめるのは 1 周で 1 回（アカウントの数だけ聞かない）', () async {
    var asked = 0;
    SecretServiceProbe.debugLockedOverride = () async {
      asked++;
      return true;
    };

    await container
        .read(accountManagerProvider.notifier)
        .retryOfflineRestores();

    expect(asked, 1);
  });
}

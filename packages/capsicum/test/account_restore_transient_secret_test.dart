import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/service/account_storage.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #959-1: secret が一過性で読めない起動を「ログアウト」にしない。
///
/// `getSecrets` は Keychain ロック（-25308）等の transient を
/// [TransientSecretUnavailableException] で通知する。索引は生きているので、
/// restoreSessions はこれを skip（再ログイン促し）ではなくオフライン保持に倒し、
/// `hasSession` を true に保って /server への引き戻し（#917 で直した「ログアウト
/// されたように見える」画面）を防ぐ。恒久的な欠落（null）は従来どおり skip。
class _MockStorage extends Mock implements AccountStorage {}

void main() {
  const key = AccountKey(
    type: BackendType.mastodon,
    host: 'mstdn.example',
    username: 'alice',
  );
  final keyStr = key.toStorageKey();

  test('secret が一過性で読めない起動はオフライン保持する（skip しない）', () async {
    final storage = _MockStorage();
    when(() => storage.getAccountKeys()).thenAnswer((_) async => [keyStr]);
    when(
      () => storage.getSecrets(keyStr),
    ).thenThrow(const TransientSecretUnavailableException('keychain locked'));

    final container = ProviderContainer(
      overrides: [accountStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);

    final skipped = await container
        .read(accountManagerProvider.notifier)
        .restoreSessions();
    final state = container.read(accountManagerProvider);

    expect(skipped, 0, reason: '一過性の未読は再ログイン促し（skip）にしない');
    expect(state.current, isNull);
    expect(state.offlineAccounts.map((o) => o.key), [key]);
    expect(state.hasSession, isTrue, reason: '/server へ引き戻さない');
  });

  test('secret が本当に無い（null）起動は従来どおり skip する', () async {
    final storage = _MockStorage();
    when(() => storage.getAccountKeys()).thenAnswer((_) async => [keyStr]);
    when(() => storage.getSecrets(keyStr)).thenAnswer((_) async => null);

    final container = ProviderContainer(
      overrides: [accountStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);

    final skipped = await container
        .read(accountManagerProvider.notifier)
        .restoreSessions();
    final state = container.read(accountManagerProvider);

    expect(skipped, 1);
    expect(state.offlineAccounts, isEmpty);
    expect(state.hasSession, isFalse, reason: '本当の欠落は再ログインへ');
  });
}

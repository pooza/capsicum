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

  /// #967 で挙動が変わった。以前は skip して一覧から丸ごと消していたが、索引に
  /// host/username は残っているので「未接続」として並べ、接続し直せば戻せる形に
  /// した。設定のインポート (#857) はアクセストークンを持ち込まない設計なので、
  /// **インポート直後は必ずこの状態になる** — ここで消すと、インポートしたはずの
  /// アカウントが 1 件も見えない。
  test('secret が本当に無い（null）起動は「未接続」として一覧に残す', () async {
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

    expect(skipped, 0, reason: '消さないので skip には数えない');
    expect(state.offlineAccounts.map((o) => o.key), [key]);
    expect(
      state.offlineAccounts.single.recoverableByRetry,
      isFalse,
      reason: 'トークンが無いので背景リトライでは戻らない',
    );
    expect(
      state.offlineAccounts.single.retrying,
      isFalse,
      reason: 'probe を組み立てられないので「再試行中」はありえない',
    );
    expect(
      state.hasSession,
      isTrue,
      reason: '/server へ引き戻すと、未接続の一覧そのものが見えなくなる',
    );
  });
}

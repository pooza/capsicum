import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/service/account_storage.dart';
import 'package:capsicum/src/service/background_notification_service.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockStorage extends Mock implements AccountStorage {}

class _FakeAdapter extends Mock implements DecentralizedBackendAdapter {}

/// #1293: デッキのドロワーを開いただけで、切替先の未読の印が消えていた。
///
/// #1286 でドロワーを開くときにフォーカス中のカラムのアカウントへ切り替える
/// ようにしたが、`switchAccount` が無条件に未読数を消していた。利用者は
/// そのアカウントの通知をまだ見ていない。
void main() {
  const alice = AccountKey(
    type: BackendType.mastodon,
    host: 'mstdn.example',
    username: 'alice',
  );
  final aliceKey = alice.toStorageKey();
  final account = Account(
    key: alice,
    adapter: _FakeAdapter(),
    user: const User(id: '1', username: 'alice', host: 'mstdn.example'),
    userSecret: const UserSecret(accessToken: 'token'),
  );

  /// ⚠ [accounts] を一覧に入れてから返す。`switchAccount` は一覧に無い
  /// アカウントを無視する (#1372)。
  ProviderContainer boot({List<Account>? accounts}) {
    final storage = _MockStorage();
    when(() => storage.touchAccount(any())).thenAnswer((_) async {});
    final container = ProviderContainer(
      overrides: [accountStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    container.read(accountManagerProvider);
    container.read(accountManagerProvider.notifier).state = AccountManagerState(
      accounts: accounts ?? [account],
    );
    return container;
  }

  Future<int?> unreadOf(String key) async =>
      (await SharedPreferences.getInstance()).getInt(
        BackgroundNotificationService.unreadCountKey(key),
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({
      BackgroundNotificationService.unreadCountKey(aliceKey): 3,
    });
  });

  test('利用者が選んだ切り替えは、未読の印を消す（従来どおり）', () async {
    boot().read(accountManagerProvider.notifier).switchAccount(account);
    await pumpEventQueue();
    expect(await unreadOf(aliceKey), isNull);
  });

  test('⚠⚠ clearUnread: false なら未読の印を残す（デッキのドロワー）', () async {
    boot()
        .read(accountManagerProvider.notifier)
        .switchAccount(account, clearUnread: false);
    await pumpEventQueue();
    expect(await unreadOf(aliceKey), 3);
  });

  group('#1372: 一覧に無いアカウントへは切り替えない', () {
    test('⚠⚠ ログアウト済み（一覧に無い）なら、現在のアカウントにも未読にも触らない', () async {
      final container = boot(accounts: const []);
      container.read(accountManagerProvider.notifier).switchAccount(account);
      await pumpEventQueue();

      final state = container.read(accountManagerProvider);
      expect(state.current, isNull, reason: 'ログアウト済みのアカウントを戻さない');
      expect(state.accounts, isEmpty);
      expect(await unreadOf(aliceKey), 3, reason: '切り替えていないので未読も消さない');
    });

    test('一覧にあれば、渡された写しではなく一覧の側を現在のアカウントにする', () async {
      final fresh = account.copyWithUser(
        const User(
          id: '1',
          username: 'alice',
          host: 'mstdn.example',
          displayName: '新しい名前',
        ),
      );
      final container = boot(accounts: [fresh]);
      container.read(accountManagerProvider.notifier).switchAccount(account);
      await pumpEventQueue();

      final current = container.read(accountManagerProvider).current;
      expect(current, same(fresh));
      expect(current!.user.displayName, '新しい名前');
    });
  });
}

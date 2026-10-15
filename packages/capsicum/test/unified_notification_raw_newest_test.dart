import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/unified_notification_provider.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1291 のリリース前レビュー: 「すべての通知」の既読は、絞り込みで落とす前の
/// 一番新しい通知まで返す。
///
/// ⚠⚠ 先頭の通知をフィルターで伏せていると、見えている先頭はその 1 つ下になる。
/// 見えている先頭で返すと、伏せた通知が未読のまま残り、バッジが 0 にならない。
class _Adapter extends Mock
    implements DecentralizedBackendAdapter, NotificationSupport {
  _Adapter(this.notifications);

  final List<Notification> notifications;

  @override
  Future<NotificationResponse> getNotifications({
    TimelineQuery? query,
    NotificationQuery? filter,
  }) async => NotificationResponse(
    notifications: notifications,
    rawCount: notifications.length,
  );
}

class _Accounts extends AccountManagerNotifier {
  _Accounts(this._accounts);

  final List<Account> _accounts;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: _accounts, current: _accounts.first);
}

Notification _mention(String id, {bool hidden = false}) => Notification(
  id: id,
  type: NotificationType.mention,
  createdAt: DateTime.utc(2026, 10, 16, 0, int.parse(id)),
  user: const User(id: 'u', username: 'someone'),
  post: Post(
    id: 'p$id',
    postedAt: DateTime.utc(2026, 10, 16),
    author: const User(id: 'u', username: 'someone'),
    content: 'ほげ',
    filterMatches: [
      if (hidden)
        const FilterMatch(
          action: FilterAction.hide,
          contexts: {FilterContext.notifications},
        ),
    ],
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('⚠⚠ 先頭を伏せていても、既読に使うのは落とす前の一番新しい通知', () async {
    SharedPreferences.setMockInitialValues(const {});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    final account = Account(
      key: const AccountKey(
        type: BackendType.mastodon,
        host: 'example.test',
        username: 'me',
      ),
      adapter: _Adapter([_mention('12', hidden: true), _mention('11')]),
      user: const User(id: 'me', username: 'me'),
      userSecret: const UserSecret(accessToken: 'token'),
    );
    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(() => _Accounts([account])),
      ],
    );
    addTearDown(container.dispose);
    container.listen(unifiedNotificationProvider, (_, _) {});

    await container.read(unifiedNotificationProvider.future);
    await pumpEventQueue();
    final state = container.read(unifiedNotificationProvider).requireValue;

    expect(state.items.map((i) => i.notification.id), ['11']);
    expect(state.rawNewestIds[account.key.toStorageKey()], '12');
  });
}

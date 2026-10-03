import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/unified_notification_provider.dart';
import 'package:capsicum/src/ui/screen/unified_notification_screen.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart' hide Notification;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1048: 束ねた通知が「N 人が…」として出ること。
///
/// ⚠ 「すべての通知」の行には**宛先アカウントのバッジ**が既にあるので、ここでは
/// 代表アイコンを重ねず人数だけ文字で出す（重ねると「どちらが自分か」が読めない）。
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

AccountKey _key(String username) => AccountKey(
  type: BackendType.misskey,
  host: '$username.example',
  username: username,
);

Account _account(String username) => Account(
  key: _key(username),
  adapter: _Adapter(),
  user: User(id: username, username: username),
  userSecret: const UserSecret(accessToken: 'token'),
);

class _FixedUnifiedNotifier extends UnifiedNotificationNotifier {
  _FixedUnifiedNotifier(this._state);

  final UnifiedNotificationState _state;

  @override
  Future<UnifiedNotificationState> build() async => _state;
}

class _TestAccountNotifier extends AccountManagerNotifier {
  _TestAccountNotifier(this._accounts);

  final List<Account> _accounts;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: _accounts, current: _accounts.first);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(WidgetTester tester, Notification notification) async {
    SharedPreferences.setMockInitialValues(const {});
    initSharedPreferencesCache(await SharedPreferences.getInstance());

    final me = _account('me');
    final state = UnifiedNotificationState(
      items: [UnifiedNotification(account: me, notification: notification)],
      totalAccounts: 1,
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) =>
              const Scaffold(body: UnifiedNotificationScreen(embedded: true)),
        ),
        GoRoute(path: '/post', builder: (_, _) => const SizedBox()),
        GoRoute(path: '/profile', builder: (_, _) => const SizedBox()),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountManagerProvider.overrideWith(() => _TestAccountNotifier([me])),
          unifiedNotificationProvider.overrideWith(
            () => _FixedUnifiedNotifier(state),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  User makeUser(String name) =>
      User(id: name, username: name, displayName: name);

  testWidgets('束ねた通知は「ほか N 人が」を出す', (tester) async {
    await pump(
      tester,
      Notification(
        id: 'n1',
        type: NotificationType.favourite,
        createdAt: DateTime.utc(2026, 1, 1),
        user: makeUser('あかね'),
        groupKey: 'favourite-500',
        groupCount: 3,
        sampleUsers: [makeUser('あかね'), makeUser('あおい')],
      ),
    );
    expect(find.text('あかね'), findsOneWidget);
    expect(find.text(' ほか2人がお気に入り'), findsOneWidget);
  });

  testWidgets('束ねていない通知は従来どおり（人数を出さない）', (tester) async {
    await pump(
      tester,
      Notification(
        id: 'n1',
        type: NotificationType.favourite,
        createdAt: DateTime.utc(2026, 1, 1),
        user: makeUser('あかね'),
      ),
    );
    expect(find.text(' がお気に入り'), findsOneWidget);
    expect(find.textContaining('ほか'), findsNothing);
  });

  testWidgets('⚠ 代表が居ない束ねは「 ほか…」で始めない', (tester) async {
    await pump(
      tester,
      Notification(
        id: 'n1',
        type: NotificationType.follow,
        createdAt: DateTime.utc(2026, 1, 1),
        groupKey: 'follow-1',
        groupCount: 5,
      ),
    );
    expect(find.text('5人がフォロー'), findsOneWidget);
  });
}

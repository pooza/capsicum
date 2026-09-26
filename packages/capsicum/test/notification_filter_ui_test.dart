import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/ui/widget/notification_filter_button.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart' hide Notification;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1042: 通知の種別フィルタの入口。
///
/// ⚠⚠ **絞り込みは 1 つの設定でアプリ全体に効く。**だから候補は全アカウントの
/// 和集合でなければならない — いま開いているアカウントの候補だけを出すと、
/// 別のアカウントで外した種別を戻す手段が無くなる。
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

/// 指定した種別だけを絞り込みの候補に持つアダプタ。
class _FilterableAdapter extends _Adapter implements NotificationSupport {
  _FilterableAdapter(this._types);

  final Set<NotificationType> _types;

  @override
  Set<NotificationType> get filterableNotificationTypes => _types;

  @override
  Future<void> clearAllNotifications() async {}

  @override
  Future<NotificationResponse> getNotifications({
    TimelineQuery? query,
    NotificationQuery? filter,
  }) async => const NotificationResponse(notifications: [], rawCount: 0);
}

/// 絞り込みに関与しないアダプタ（通知に対応していないアカウント）。
class _PlainAdapter extends _Adapter {}

Account _account(String username, DecentralizedBackendAdapter adapter) =>
    Account(
      key: AccountKey(
        type: BackendType.misskey,
        host: '$username.example',
        username: username,
      ),
      adapter: adapter,
      user: User(id: username, username: username),
      userSecret: const UserSecret(accessToken: 'token'),
    );

class _TestAccountNotifier extends AccountManagerNotifier {
  _TestAccountNotifier(this._accounts);

  final List<Account> _accounts;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: _accounts, current: _accounts.first);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
  });

  ProviderContainer containerFor(List<Account> accounts) {
    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(
          () => _TestAccountNotifier(accounts),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('notificationFilterableTypesProvider', () {
    test('⚠ 候補は全アカウントの和集合', () {
      final container = containerFor([
        // Mastodon 相当（お気に入りがある・リアクションが無い）。
        _account(
          'masto',
          _FilterableAdapter({
            NotificationType.mention,
            NotificationType.favourite,
          }),
        ),
        // Misskey 相当（リアクションがある・お気に入りが無い）。
        _account(
          'misskey',
          _FilterableAdapter({
            NotificationType.mention,
            NotificationType.reaction,
          }),
        ),
      ]);
      expect(container.read(notificationFilterableTypesProvider), [
        NotificationType.mention,
        NotificationType.favourite,
        NotificationType.reaction,
      ]);
    });

    test('⚠ 並びは NotificationType.values の順（アカウントを足す順で変わらない）', () {
      final reversed = containerFor([
        _account(
          'a',
          _FilterableAdapter({
            NotificationType.reaction,
            NotificationType.mention,
          }),
        ),
      ]);
      expect(reversed.read(notificationFilterableTypesProvider), [
        NotificationType.mention,
        NotificationType.reaction,
      ]);
    });

    test('通知に対応していないアカウントは候補を増やさない', () {
      final container = containerFor([
        _account('plain', _PlainAdapter()),
        _account('misskey', _FilterableAdapter({NotificationType.follow})),
      ]);
      expect(container.read(notificationFilterableTypesProvider), [
        NotificationType.follow,
      ]);
    });

    test('⚠ 「その他」は候補に出さない（サーバー側の名前を列挙できない）', () {
      final container = containerFor([
        _account(
          'x',
          // アダプタが誤って other を返しても、`NotificationType.values` の
          // 順に並べ替える過程では落ちない。**落とすのはアダプタ側の責務**
          // （`mastodonFilterableNotificationTypes` は型マップの値なので
          // other を含まない）ことを、ここで明示しておく。
          _FilterableAdapter({NotificationType.follow}),
        ),
      ]);
      expect(
        container.read(notificationFilterableTypesProvider),
        isNot(contains(NotificationType.other)),
      );
    });
  });

  group('NotificationFilterButton', () {
    Future<ProviderContainer> pump(WidgetTester tester) async {
      final container = containerFor([
        _account(
          'misskey',
          _FilterableAdapter({
            NotificationType.mention,
            NotificationType.reaction,
          }),
        ),
      ]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              appBar: null,
              body: Center(child: NotificationFilterButton()),
            ),
          ),
        ),
      );
      return container;
    }

    testWidgets('⚠ 絞り込み中はアイコンの形が変わる（見えないまま効いている設定にしない）', (tester) async {
      final container = await pump(tester);
      expect(find.byIcon(Icons.filter_list), findsOneWidget);

      await container
          .read(notificationExcludedTypesProvider.notifier)
          .setExcluded(NotificationType.reaction, true);
      await tester.pump();

      expect(find.byIcon(Icons.filter_list), findsNothing);
      expect(find.byIcon(Icons.filter_list_off), findsOneWidget);
    });

    testWidgets('チェックを外すと除外され、「すべて表示」で戻る', (tester) async {
      final container = await pump(tester);
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();

      // 候補は和集合の順（メンション → リアクション）。
      expect(find.text('メンション'), findsOneWidget);
      expect(find.text('リアクション'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('notification-filter-reaction')),
      );
      await tester.pumpAndSettle();
      expect(container.read(notificationExcludedTypesProvider), {
        NotificationType.reaction,
      });

      await tester.tap(find.text('すべて表示'));
      await tester.pumpAndSettle();
      expect(container.read(notificationExcludedTypesProvider), isEmpty);
    });

    testWidgets('⚠ 何も外していないときは「すべて表示」を押せない', (tester) async {
      await pump(tester);
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('すべて表示'),
          matching: find.byType(TextButton),
        ),
      );
      expect(button.onPressed, isNull);
    });
  });
}

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/deck_column.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/unified_notification_provider.dart';
import 'package:capsicum/src/ui/screen/unified_notification_screen.dart';
import 'package:capsicum/src/ui/util/deck_navigation.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart' hide Notification;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1173: 「すべての通知」をデッキのカラムとして出す（`docs/deck-ui-plan.md`
/// 決定済み事項 7-3）。
///
/// ⚠⚠ **いちばん危ないのは `switchAccount`。**タブ UI の「すべての通知」は通知を
/// 押すと**現在のアカウントを切り替えてから**開く。デッキは現在のアカウントが
/// 変わるとカラムのコンテナの割り当てが組み替わる（決定済み事項 8）ので、
/// **そのまま持ち込むと通知 1 つで裏側が全部組み変わる。**
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

/// 用意した状態をそのまま返す「すべての通知」。
class _FixedUnifiedNotifier extends UnifiedNotificationNotifier {
  _FixedUnifiedNotifier(this._state);

  final UnifiedNotificationState _state;

  @override
  Future<UnifiedNotificationState> build() async => _state;
}

/// 切り替えが呼ばれたかを覚えるアカウント管理。
class _TestAccountNotifier extends AccountManagerNotifier {
  _TestAccountNotifier(this._accounts, this.switched);

  final List<Account> _accounts;
  final List<AccountKey> switched;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: _accounts, current: _accounts.first);

  @override
  Future<void> switchAccount(Account account) async {
    switched.add(account.key);
  }
}

Post _post(String id, String host) => Post(
  id: id,
  postedAt: DateTime.utc(2026, 1, 1),
  author: User(id: 'author', username: 'author', host: host),
  content: 'ほげ',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 「すべての通知」を [inDeck] のとおりに置き、1 件だけ通知を出す。
  ///
  /// 返すのは (切り替えが呼ばれたアカウント, カラムとして開かれた記録)。
  Future<
    ({List<AccountKey> switched, List<(TabType, AccountKey?)> openedColumns})
  >
  pump(WidgetTester tester, {required bool inDeck}) async {
    SharedPreferences.setMockInitialValues(const {});
    initSharedPreferencesCache(await SharedPreferences.getInstance());

    final me = _account('me');
    final other = _account('other');
    final switched = <AccountKey>[];
    final openedColumns = <(TabType, AccountKey?)>[];

    // ⚠ 通知は **other** のもの。デッキのカラムは **me** に置く。この食い違いが
    // 「どちらのアカウントで開くか」を見分ける仕掛け。
    final state = UnifiedNotificationState(
      items: [
        UnifiedNotification(
          account: other,
          notification: Notification(
            id: 'n1',
            type: NotificationType.mention,
            createdAt: DateTime.utc(2026, 1, 1),
            user: other.user,
            post: _post('p1', other.key.host),
          ),
        ),
      ],
      totalAccounts: 2,
    );

    const column = DeckColumn(
      id: 'c1',
      account: AccountKey(
        type: BackendType.misskey,
        host: 'me.example',
        username: 'me',
      ),
      tab: AllNotificationsTab(),
    );

    Widget screen = const UnifiedNotificationScreen(embedded: true);
    if (inDeck) {
      screen = DeckColumnScope(
        column: column,
        onOpen: (from, tab, seed, {account}) =>
            openedColumns.add((tab, account)),
        onClose: (_) {},
        child: screen,
      );
    }

    // ⚠ デッキの外では `openPost` が `context.push('/post')` に落ちるので、
    // GoRouter が居ないと「No GoRouter found in context」で落ちる。押した先は
    // この検査の対象ではないので、空の行き先だけ用意する。
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(body: screen),
        ),
        GoRoute(path: '/post', builder: (_, _) => const SizedBox()),
        GoRoute(path: '/profile', builder: (_, _) => const SizedBox()),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountManagerProvider.overrideWith(
            () => _TestAccountNotifier([me, other], switched),
          ),
          unifiedNotificationProvider.overrideWith(
            () => _FixedUnifiedNotifier(state),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    return (switched: switched, openedColumns: openedColumns);
  }

  testWidgets('前提: 通知が 1 件出ていて、押せる', (tester) async {
    await pump(tester, inDeck: false);

    expect(find.byType(InkWell), findsWidgets);
    expect(find.textContaining('ほげ'), findsWidgets);
  });

  testWidgets('デッキの外では、これまでどおり現在のアカウントを切り替える', (tester) async {
    final r = await pump(tester, inDeck: false);

    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();

    expect(r.switched, [_key('other')], reason: 'タブ UI の挙動は変えない（#345 の導線）');
    expect(r.openedColumns, isEmpty);
  });

  testWidgets('⚠⚠ デッキの中では現在のアカウントを切り替えない', (tester) async {
    final r = await pump(tester, inDeck: true);

    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();

    expect(
      r.switched,
      isEmpty,
      reason: '⚠⚠ 切り替えるとカラムのコンテナの割り当てが組み替わる（決定済み事項 8）',
    );
  });

  testWidgets('⚠⚠ デッキの中では、その通知のアカウントのカラムとして開く', (tester) async {
    final r = await pump(tester, inDeck: true);

    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();

    expect(r.openedColumns, hasLength(1));
    final (tab, account) = r.openedColumns.single;
    expect(tab, const PostThreadTab('p1'));
    expect(
      account,
      _key('other'),
      reason: '⚠ 元のカラム（me）を引き継ぐと、別サーバーの id を引いて別の投稿を指す',
    );
  });

  testWidgets('⚠ カラムでは AppBar を持たない（見出しはカラムのヘッダー）', (tester) async {
    await pump(tester, inDeck: true);

    // ⚠ 「無い」だけを見ると、中身ごと描けていなくても通る。先に描けていることを見る。
    expect(find.textContaining('ほげ'), findsWidgets);
    expect(find.text('すべての通知'), findsNothing);
  });
}

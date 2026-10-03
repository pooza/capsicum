import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/deck_screen.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1153: タブ UI とデッキの切り替え。
///
/// ⚠⚠ **見た目は切り替えスイッチだが、実体は画面遷移。**デッキは HomeScreen の
/// 上に push され、HomeScreen が下に残って同じ TL を watch し続けることが前提
/// （`docs/deck-ui-plan.md` 決定済み事項 8）。「タブ表示に切り替え」で
/// **HomeScreen を作り直さずに戻る**ことを見る。
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

class _TestAccountNotifier extends AccountManagerNotifier {
  @override
  AccountManagerState build() {
    final account = Account(
      key: const AccountKey(
        type: BackendType.misskey,
        host: 'misskey.example',
        username: 'me',
      ),
      adapter: _Adapter(),
      user: const User(id: 'me', username: 'me'),
      userSecret: const UserSecret(accessToken: 'token'),
    );
    return AccountManagerState(accounts: [account], current: account);
  }
}

/// タブ UI の代わり。作り直されたかを数える。
class _Home extends StatefulWidget {
  const _Home({required this.inits});

  final List<int> inits;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  @override
  void initState() {
    super.initState();
    widget.inits.add(1);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(
      onPressed: () => context.push('/deck'),
      child: const Text('ホーム'),
    ),
  );
}

void main() {
  late List<int> homeInits;

  setUp(() async {
    homeInits = [];
    SharedPreferences.setMockInitialValues({});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
  });

  Future<void> pump(WidgetTester tester, {required String initial}) async {
    final router = GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => _Home(inits: homeInits),
        ),
        GoRoute(
          path: '/deck',
          builder: (_, _) =>
              DeckScreen(columnBuilder: (column) => const SizedBox()),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountManagerProvider.overrideWith(_TestAccountNotifier.new),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('タブ UI から開いたデッキは、切り替えで元のタブ UI を作り直さずに戻る', (tester) async {
    await pump(tester, initial: '/home');
    await tester.tap(find.text('ホーム'));
    await tester.pumpAndSettle();
    expect(find.text('デッキ'), findsOneWidget);
    // 戻る（←）は出さない。戻るのは右端の切り替えに一本化した。
    expect(find.byType(BackButton), findsNothing);

    await tester.tap(find.byTooltip('タブ表示に切り替え'));
    await tester.pumpAndSettle();

    expect(find.text('ホーム'), findsOneWidget);
    expect(find.text('デッキ'), findsNothing);
    // ⚠ 作り直していない（下に残っていた HomeScreen がそのまま出る）。
    expect(homeInits, hasLength(1));
  });

  testWidgets('下に何も無いデッキからは、ホームへ出る', (tester) async {
    await pump(tester, initial: '/deck');
    expect(find.text('デッキ'), findsOneWidget);

    await tester.tap(find.byTooltip('タブ表示に切り替え'));
    await tester.pumpAndSettle();

    expect(find.text('ホーム'), findsOneWidget);
  });
}

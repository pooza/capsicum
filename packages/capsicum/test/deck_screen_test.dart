import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/deck_column.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/ui/screen/deck_screen.dart';
import 'package:capsicum/src/ui/util/deck_navigation.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1092: デッキ画面のカラムコンテナ。
///
/// カラムの中身は差し替え口（`columnBuilder`）で軽いものにして、**コンテナの
/// 振る舞いだけ**を見る（`PostTile` の依存一式を用意しないため）。
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

Account _account(String username) => Account(
  key: AccountKey(
    type: BackendType.misskey,
    host: 'misskey.example',
    username: username,
  ),
  adapter: _Adapter(),
  user: User(id: username, username: username),
  userSecret: const UserSecret(accessToken: 'token'),
);

/// ログイン済みのアカウントを差し替えられるアカウント管理。先頭が現在のアカウント。
class _TestAccountNotifier extends AccountManagerNotifier {
  _TestAccountNotifier(this._accounts);

  final List<Account> _accounts;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: _accounts, current: _accounts.first);

  void replaceAccounts(List<Account> accounts) =>
      state = AccountManagerState(accounts: accounts, current: accounts.first);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 各カラムの `initState` が何回走ったか（カラム id → 回数）。
  final initCounts = <String, int>{};

  /// 各カラムが置かれた位置の `ProviderContainer`（カラム id → コンテナ）。
  final containers = <String, ProviderContainer>{};

  setUp(() {
    initCounts.clear();
    containers.clear();
  });

  /// [lines] は `<id>|<アカウント名>|<種別>`（ホストは misskey.example）。
  Future<void> pumpDeckLines(
    WidgetTester tester, {
    required Size size,
    required List<String> lines,
    List<Account>? accounts,
  }) async {
    SharedPreferences.setMockInitialValues({
      'deck_columns': [
        for (final line in lines)
          () {
            final [id, user, tab] = line.split('|');
            return '$id|misskey://$user@misskey.example|$tab';
          }(),
      ],
    });
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountManagerProvider.overrideWith(
            () => _TestAccountNotifier(accounts ?? [_account('me')]),
          ),
        ],
        child: MaterialApp(
          home: DeckScreen(
            columnBuilder: (column) => _StubColumn(
              key: ValueKey('stub-${column.id}'),
              column: column,
              initCounts: initCounts,
              containers: containers,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpDeck(
    WidgetTester tester, {
    required Size size,
    required List<String> columnIds,
  }) => pumpDeckLines(
    tester,
    size: size,
    lines: [for (final id in columnIds) '$id|me|hashtag:$id'],
  );

  double columnWidthOf(WidgetTester tester, String id) =>
      tester.getSize(find.byKey(ValueKey('stub-$id'))).width;

  /// カラムを横に並べるスクロール。⚠ ウィジェットの型（`SingleChildScrollView`
  /// 等）では探さない。コンテナの作りを変えたとき、**検査が型の探索で落ちて、
  /// 見たいこと（カラムが生きているか）を見ないまま赤になる**のを避ける。
  final horizontalScroller = find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.right,
  );

  double horizontalOffset(WidgetTester tester) =>
      tester.state<ScrollableState>(horizontalScroller).position.pixels;

  testWidgets('カラムが無ければその旨を出す', (tester) async {
    await pumpDeck(tester, size: const Size(800, 600), columnIds: const []);
    expect(find.text('カラムがありません'), findsOneWidget);
  });

  testWidgets('800px では 2 本が画面に入り、各 400px', (tester) async {
    await pumpDeck(
      tester,
      size: const Size(800, 600),
      columnIds: const ['a', 'b', 'c'],
    );
    expect(columnWidthOf(tester, 'a'), 400);
    expect(columnWidthOf(tester, 'c'), 400);
  });

  testWidgets('狭い幅では 1 カラムで全幅になり、カラムの境界で止まる（ページャ）', (tester) async {
    await pumpDeck(
      tester,
      size: const Size(390, 700),
      columnIds: const ['a', 'b', 'c'],
    );
    expect(columnWidthOf(tester, 'a'), 390);

    // 半分弱しか動かさなければ元のカラムへ戻る。
    await tester.drag(horizontalScroller, const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(horizontalOffset(tester), 0);

    // 半分を超えて動かせば次のカラムで止まる。
    await tester.drag(horizontalScroller, const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(horizontalOffset(tester), 390);
  });

  testWidgets('⚠⚠ 横に 1 つ動いて戻っても、元のカラムは作り直されず縦のスクロール位置も残る', (tester) async {
    await pumpDeck(
      tester,
      size: const Size(390, 700),
      columnIds: const ['a', 'b', 'c'],
    );

    // カラム a を縦にスクロールしておく。
    await tester.drag(
      find.byKey(const ValueKey('list-a')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    final offsetBefore = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const ValueKey('list-a')),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;
    expect(offsetBefore, greaterThan(0), reason: '前提: 縦に動いている');

    // 横に 2 つ進んで戻る。
    await tester.drag(horizontalScroller, const Offset(-250, 0));
    await tester.pumpAndSettle();
    await tester.drag(horizontalScroller, const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(horizontalOffset(tester), 780, reason: '前提: カラム c まで来ている');
    await tester.drag(horizontalScroller, const Offset(250, 0));
    await tester.pumpAndSettle();
    await tester.drag(horizontalScroller, const Offset(250, 0));
    await tester.pumpAndSettle();
    expect(horizontalOffset(tester), 0);

    expect(initCounts, {
      'a': 1,
      'b': 1,
      'c': 1,
    }, reason: '画面外へ出たカラムを捨てて作り直していない');
    final offsetAfter = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const ValueKey('list-a')),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;
    expect(offsetAfter, offsetBefore);
  });

  group('カラムごとのアカウント (#1096)', () {
    Future<void> pumpTwoAccounts(WidgetTester tester, List<String> lines) =>
        pumpDeckLines(
          tester,
          size: const Size(1600, 600),
          lines: lines,
          accounts: [_account('me'), _account('other')],
        );

    String accountSeenBy(WidgetTester tester, String id) =>
        tester.widget<Text>(find.byKey(ValueKey('account-$id'))).data!;

    testWidgets('⚠⚠ 別アカウントのカラムの中では、「現在のアカウント」がそのカラムのアカウントになる', (tester) async {
      await pumpTwoAccounts(tester, [
        'a|me|timeline:home',
        'b|other|timeline:home',
      ]);

      expect(accountSeenBy(tester, 'a'), 'me');
      expect(accountSeenBy(tester, 'b'), 'other');
    });

    testWidgets('⚠⚠ 同じアカウントのカラムはコンテナを共有し、現在のアカウントのカラムはルートのまま', (tester) async {
      await pumpTwoAccounts(tester, [
        'a|me|timeline:home',
        'b|other|timeline:home',
        'c|other|hashtag:x',
      ]);

      // 別アカウント other の 2 本は同じコンテナ（重複カラムが TL を共有し、
      // 購読キーがぶつからない・未決事項 10）。
      expect(identical(containers['b'], containers['c']), isTrue);
      // 現在のアカウント me は HomeScreen と同じルート（決定済み事項 8）。
      final root = ProviderScope.containerOf(
        tester.element(find.byType(DeckScreen)),
      );
      expect(identical(containers['a'], root), isTrue);
      expect(identical(containers['b'], root), isFalse);
    });

    testWidgets('同じアカウントの Account が差し替わっても（再接続等）、コンテナは作り直さず中身だけ新しくなる', (
      tester,
    ) async {
      await pumpTwoAccounts(tester, [
        'a|me|timeline:home',
        'b|other|timeline:home',
      ]);
      final before = containers['b']!;
      final notifier =
          ProviderScope.containerOf(
                tester.element(find.byType(DeckScreen)),
              ).read(accountManagerProvider.notifier)
              as _TestAccountNotifier;

      final reconnected = _account('other');
      notifier.replaceAccounts([_account('me'), reconnected]);
      await tester.pumpAndSettle();

      expect(identical(containers['b'], before), isTrue);
      expect(initCounts['b'], 1, reason: 'カラムを作り直していない');
      expect(
        identical(before.read(currentAccountProvider), reconnected),
        isTrue,
        reason: 'カラムの中の「現在のアカウント」は新しい Account を指す',
      );
    });

    testWidgets('⚠⚠ 別アカウントのカラムから開いたシート / ダイアログ / メニューも、そのアカウントで動く (#1149)', (
      tester,
    ) async {
      await pumpTwoAccounts(tester, [
        'a|me|timeline:home',
        'b|other|timeline:home',
      ]);

      await tester.tap(find.byKey(const ValueKey('sheet-b')));
      await tester.pumpAndSettle();
      expect(find.text('sheet:other'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('dialog-b')));
      await tester.pumpAndSettle();
      expect(find.text('dialog:other'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('menu-b')));
      await tester.pumpAndSettle();
      expect(find.text('menu:other'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // 現在のアカウントのカラムからは、現在のアカウント。
      await tester.tap(find.byKey(const ValueKey('sheet-a')));
      await tester.pumpAndSettle();
      expect(find.text('sheet:me'), findsOneWidget);
    });

    testWidgets('接続されていないアカウントのカラムは、消さずに案内を出す', (tester) async {
      await pumpTwoAccounts(tester, [
        'a|me|timeline:home',
        'z|ghost|timeline:home',
      ]);

      expect(find.byKey(const ValueKey('stub-z')), findsNothing);
      expect(find.text('@ghost@misskey.example は接続されていません'), findsOneWidget);
    });
  });

  group('カラムから開いたものは新しいカラムになる (#1148)', () {
    List<DeckColumn> columnsOf(WidgetTester tester) {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DeckScreen)),
      );
      return container.read(deckColumnsProvider);
    }

    testWidgets('⚠⚠ 元のカラムの右隣に、元のカラムのアカウントで足される', (tester) async {
      await pumpDeckLines(
        tester,
        size: const Size(1600, 600),
        lines: const [
          'a|me|timeline:home',
          'b|other|timeline:home',
          'c|me|timeline:local',
        ],
        accounts: [_account('me'), _account('other')],
      );

      await tester.tap(find.byKey(const ValueKey('open-post-b')));
      await tester.pumpAndSettle();

      final columns = columnsOf(tester);
      expect(columns.map((c) => c.id).take(2), ['a', 'b']);
      final opened = columns[2];
      expect(opened.tab, const PostThreadTab('p-b'));
      expect(opened.account.username, 'other');
      expect((opened.seed! as Post).id, 'p-b', reason: '開いた投稿をそのまま渡す');
      expect(columns.last.id, 'c');
      // 足したカラムの中も、そのアカウントで動く（#1096 のコンテナに乗る）。
      expect(
        tester.widget<Text>(find.byKey(ValueKey('account-${opened.id}'))).data,
        'other',
      );
    });

    testWidgets('⚠ カラムから開いたシートの中から開いても、元のカラムの右隣に足される', (tester) async {
      await pumpDeckLines(
        tester,
        size: const Size(1600, 600),
        lines: const ['a|me|timeline:home', 'b|other|timeline:home'],
        accounts: [_account('me'), _account('other')],
      );

      await tester.tap(find.byKey(const ValueKey('open-profile-sheet-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sheet-open-profile')));
      await tester.pumpAndSettle();

      final columns = columnsOf(tester);
      expect(columns.map((c) => c.tab), [
        const TimelineTab(TimelineType.home),
        const ProfileTab('u-sheet'),
        const TimelineTab(TimelineType.home),
      ]);
      expect(columns[1].account.username, 'me');
    });

    testWidgets('足したカラムが画面の外なら、見える位置まで横に送る', (tester) async {
      // 800px = 2 本。b から開くと 3 本目に入り、画面の外になる。
      await pumpDeckLines(
        tester,
        size: const Size(800, 600),
        lines: const ['a|me|timeline:home', 'b|me|timeline:local'],
      );
      expect(horizontalOffset(tester), 0);

      await tester.tap(find.byKey(const ValueKey('open-post-b')));
      await tester.pumpAndSettle();

      expect(columnsOf(tester), hasLength(3));
      expect(horizontalOffset(tester), 400, reason: 'カラム 1 本ぶん送って 3 本目を見せる');
    });

    testWidgets('⚠⚠ 一覧・画面（実績等）も右隣に元のアカウントで足される (#1150)', (tester) async {
      await pumpDeckLines(
        tester,
        size: const Size(1600, 600),
        lines: const ['a|me|timeline:home', 'b|other|timeline:home'],
        accounts: [_account('me'), _account('other')],
      );

      await tester.tap(find.byKey(const ValueKey('open-achievements-b')));
      await tester.pumpAndSettle();

      final columns = columnsOf(tester);
      expect(columns, hasLength(3));
      expect(columns.last.tab, const AchievementsTab('u-b'));
      expect(columns.last.account.username, 'other');
      expect(columns.last.seed, '名前-b', reason: '見出し用の表示名を渡す');
    });

    testWidgets('中身の画面が閉じると、デッキ画面ではなくそのカラムだけが外れる (#1150)', (tester) async {
      await pumpDeckLines(
        tester,
        size: const Size(1600, 600),
        lines: const ['a|me|timeline:home', 'b|me|timeline:local'],
      );

      await tester.tap(find.byKey(const ValueKey('close-a')));
      await tester.pumpAndSettle();

      expect(columnsOf(tester).map((c) => c.id), ['b']);
      expect(find.byType(DeckScreen), findsOneWidget, reason: 'pop していない');
    });
  });
}

/// 縦に長いリストを持つだけのカラム。`initState` の回数と、自分の位置で見える
/// 「現在のアカウント」・コンテナを記録する。
class _StubColumn extends ConsumerStatefulWidget {
  const _StubColumn({
    super.key,
    required this.column,
    required this.initCounts,
    required this.containers,
  });

  final DeckColumn column;
  final Map<String, int> initCounts;
  final Map<String, ProviderContainer> containers;

  @override
  ConsumerState<_StubColumn> createState() => _StubColumnState();
}

class _StubColumnState extends ConsumerState<_StubColumn> {
  @override
  void initState() {
    super.initState();
    widget.initCounts.update(widget.column.id, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) {
    widget.containers[widget.column.id] = ProviderScope.containerOf(context);
    final account = ref.watch(currentAccountKeyProvider);
    final id = widget.column.id;
    // 開いた先で見える「現在のアカウント」。
    Widget seen(String where) => Consumer(
      builder: (_, r, _) =>
          Text('$where:${r.watch(currentAccountKeyProvider)?.username}'),
    );
    return Column(
      children: [
        Text(
          account?.username ?? '-',
          key: ValueKey('account-${widget.column.id}'),
        ),
        Wrap(
          children: [
            TextButton(
              key: ValueKey('sheet-$id'),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => seen('sheet'),
              ),
              child: const Text('S'),
            ),
            TextButton(
              key: ValueKey('dialog-$id'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => Dialog(child: seen('dialog')),
              ),
              child: const Text('D'),
            ),
            PopupMenuButton<int>(
              key: ValueKey('menu-$id'),
              itemBuilder: (_) => [
                PopupMenuItem(value: 1, child: seen('menu')),
              ],
            ),
            // #1148: カラムの中から投稿を開く。
            TextButton(
              key: ValueKey('open-post-$id'),
              onPressed: () => openPost(
                context,
                Post(
                  id: 'p-$id',
                  postedAt: DateTime(2026),
                  author: const User(id: 'author', username: 'author'),
                ),
              ),
              child: const Text('P'),
            ),
            // #1150: 一覧・画面を開く / 中身の画面が自分を閉じる。
            TextButton(
              key: ValueKey('open-achievements-$id'),
              onPressed: () => openAchievements(
                context,
                userId: 'u-$id',
                displayName: '名前-$id',
              ),
              child: const Text('A'),
            ),
            TextButton(
              key: ValueKey('close-$id'),
              onPressed: () => screenCloser(context)(),
              child: const Text('X'),
            ),
            // #1148: 長押しシートの「プロフィールを表示」の形（シートの中から開く）。
            TextButton(
              key: ValueKey('open-profile-sheet-$id'),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (sheetContext) => TextButton(
                  key: const ValueKey('sheet-open-profile'),
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    openProfile(
                      sheetContext,
                      const User(id: 'u-sheet', username: 'u'),
                    );
                  },
                  child: const Text('プロフィール'),
                ),
              ),
              child: const Text('U'),
            ),
          ],
        ),
        Expanded(
          child: ListView.builder(
            key: ValueKey('list-${widget.column.id}'),
            itemCount: 100,
            itemBuilder: (_, i) =>
                SizedBox(height: 40, child: Text('${widget.column.id}-$i')),
          ),
        ),
      ],
    );
  }
}

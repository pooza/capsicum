import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/antenna_edit_screen.dart';
import 'package:capsicum/src/ui/screen/antenna_management_screen.dart';
import 'package:capsicum/src/ui/widget/home_menu.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1052: アンテナの管理画面・操作のシート・作成 / 編集。型はチャンネル（#1051）。
class _Adapter extends Mock
    implements
        DecentralizedBackendAdapter,
        AntennaSupport,
        AntennaManagementSupport {}

class _DraftFake extends Fake implements AntennaDraft {}

class _AccountNotifier extends AccountManagerNotifier {
  _AccountNotifier(this._account);

  final Account _account;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: [_account], current: _account);
}

const _live = Antenna(
  id: 'a1',
  name: '実況',
  conditions: AntennaDraft(
    name: '実況',
    source: AntennaSource.users,
    keywords: [
      ['プリキュア', '実況'],
      ['precure'],
    ],
    users: ['@a', '@b@example.com'],
    withReplies: true,
  ),
);

void main() {
  late _Adapter adapter;

  setUpAll(() => registerFallbackValue(_DraftFake()));

  setUp(() {
    // 画面が端末の設定（絵文字の大きさなど）を読む。
    SharedPreferences.setMockInitialValues({});
    adapter = _Adapter();
    when(() => adapter.getAntennas()).thenAnswer((_) async => [_live]);
  });

  Account account() => Account(
    key: const AccountKey(
      type: BackendType.misskey,
      host: 'misskey.example',
      username: 'me',
    ),
    adapter: adapter,
    user: const User(id: 'me', username: 'me'),
    userSecret: const UserSecret(accessToken: 'token'),
  );

  Future<void> pump(WidgetTester tester, Widget home) async {
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => home),
        GoRoute(
          path: '/antennas/edit',
          builder: (context, state) => Scaffold(
            body: Text(
              '編集の画面:${state.extra is Antenna ? (state.extra as Antenna).id : "新規"}',
            ),
          ),
        ),
        GoRoute(
          path: '/antennas/manage',
          builder: (_, _) => const Scaffold(body: Text('管理の画面')),
        ),
        GoRoute(
          path: '/antenna/:id',
          builder: (_, state) =>
              Scaffold(body: Text('アンテナ:${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountManagerProvider.overrideWith(
            () => _AccountNotifier(account()),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('対象: Web と同じくホームとリストは出さず、今の値なら残す', () {
    expect(antennaSourceChoices(AntennaSource.all), [
      AntennaSource.all,
      AntennaSource.users,
      AntennaSource.usersBlacklist,
    ]);
    expect(
      antennaSourceChoices(AntennaSource.list),
      contains(AntennaSource.list),
    );
    expect(
      antennaSourceChoices(AntennaSource.home),
      contains(AntennaSource.home),
    );
  });

  test('行の 2 行目はキーワードを「 / 」で並べる', () {
    expect(antennaKeywordsSummary(_live), 'プリキュア 実況 / precure');
    expect(antennaKeywordsSummary(const Antenna(id: 'x', name: 'x')), isNull);
  });

  group('管理画面', () {
    testWidgets('一覧を出し、行を押すとアンテナを開く', (tester) async {
      await pump(tester, const AntennaManagementScreen());

      expect(find.text('実況'), findsOneWidget);
      await tester.tap(find.text('実況'));
      await tester.pumpAndSettle();

      expect(find.text('アンテナ:a1'), findsOneWidget);
    });

    testWidgets('＋で作成の画面へ行く', (tester) async {
      await pump(tester, const AntennaManagementScreen());

      await tester.tap(find.byTooltip('新規作成'));
      await tester.pumpAndSettle();

      expect(find.text('編集の画面:新規'), findsOneWidget);
    });

    testWidgets('行の … から編集の画面へ、そのアンテナを持って行く', (tester) async {
      await pump(tester, const AntennaManagementScreen());

      await tester.tap(find.byTooltip('アンテナの操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('編集'));
      await tester.pumpAndSettle();

      expect(find.text('編集の画面:a1'), findsOneWidget);
    });

    testWidgets('削除は確かめてから送り、一覧を取り直す', (tester) async {
      when(() => adapter.deleteAntenna('a1')).thenAnswer((_) async {});
      await pump(tester, const AntennaManagementScreen());

      await tester.tap(find.byTooltip('アンテナの操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('削除'));
      await tester.pumpAndSettle();
      expect(find.textContaining('元に戻せません'), findsOneWidget);
      verifyNever(() => adapter.deleteAntenna(any()));

      await tester.tap(find.widgetWithText(FilledButton, '削除'));
      await tester.pumpAndSettle();

      verify(() => adapter.deleteAntenna('a1')).called(1);
      verify(() => adapter.getAntennas()).called(2);
      expect(find.text('アンテナを削除しました'), findsOneWidget);
    });

    testWidgets('⚠ 削除をやめたら送らない', (tester) async {
      await pump(tester, const AntennaManagementScreen());

      await tester.tap(find.byTooltip('アンテナの操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('削除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();

      verifyNever(() => adapter.deleteAntenna(any()));
    });
  });

  group('作成 / 編集の画面', () {
    Future<List<bool?>> pushEdit(
      WidgetTester tester, {
      Antenna? antenna,
    }) async {
      final results = <bool?>[];
      await pump(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                results.add(
                  await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => AntennaEditScreen(antenna: antenna),
                    ),
                  ),
                );
              },
              child: const Text('開く'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
      return results;
    }

    Finder field(String label) => find.widgetWithText(TextField, label);

    testWidgets('名前が空なら送らない', (tester) async {
      await pushEdit(tester);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('名前を入れてください'), findsOneWidget);
      verifyNever(() => adapter.createAntenna(any()));
    });

    testWidgets('⚠ キーワードも除外キーワードも空なら送らない（サーバーが断る）', (tester) async {
      await pushEdit(tester);

      await tester.enterText(field('名前'), '新しい');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('キーワードか除外キーワードを入れてください'), findsOneWidget);
      verifyNever(() => adapter.createAntenna(any()));
    });

    testWidgets('入力したものを Web と同じ規則で組んで送る', (tester) async {
      when(() => adapter.createAntenna(any())).thenAnswer((_) async {});
      final results = await pushEdit(tester);

      await tester.enterText(field('名前'), ' 実況 ');
      await tester.enterText(field('キーワード'), 'プリキュア 実況\nprecure');
      await tester.tap(find.text('Bot を除く'));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(results, [true], reason: '閉じて、一覧へ取り直しを促す');
      final draft =
          verify(() => adapter.createAntenna(captureAny())).captured.single
              as AntennaDraft;
      expect(draft.name, '実況');
      expect(draft.keywords, [
        ['プリキュア', '実況'],
        ['precure'],
      ]);
      expect(draft.excludeBots, isTrue);
      expect(draft.source, AntennaSource.all);
    });

    testWidgets('編集は今の値を出し、そのアンテナへ送る', (tester) async {
      when(() => adapter.updateAntenna('a1', any())).thenAnswer((_) async {});
      final results = await pushEdit(tester, antenna: _live);

      expect(find.text('プリキュア 実況\nprecure'), findsOneWidget);
      expect(find.text('@a\n@b@example.com'), findsOneWidget);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final draft =
          verify(
                () => adapter.updateAntenna('a1', captureAny()),
              ).captured.single
              as AntennaDraft;
      expect(draft.source, AntennaSource.users);
      expect(draft.users, ['@a', '@b@example.com']);
      expect(draft.withReplies, isTrue);
      expect(results, [true]);
    });

    testWidgets('上限に当たったら、そう知らせて留まる', (tester) async {
      when(
        () => adapter.createAntenna(any()),
      ).thenThrow(const AntennaLimitReached());
      await pushEdit(tester);

      await tester.enterText(field('名前'), 'x');
      await tester.enterText(field('キーワード'), 'a');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('このアカウントでは、これ以上アンテナを作れません'), findsOneWidget);
      expect(find.byType(AntennaEditScreen), findsOneWidget);
    });
  });

  group('ドロワーのチューザ', () {
    Future<void> openChooser(WidgetTester tester) async {
      await pump(
        tester,
        Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => showAntennaList(context, ref),
              child: const Text('開く'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
    }

    testWidgets('⚠⚠ 0 件でも開いて、管理の画面へ行ける', (tester) async {
      when(() => adapter.getAntennas()).thenAnswer((_) async => []);
      await openChooser(tester);

      expect(find.text('アンテナはありません'), findsOneWidget);
      await tester.tap(find.text('アンテナを管理する'));
      await tester.pumpAndSettle();

      expect(find.text('管理の画面'), findsOneWidget);
    });

    testWidgets('アンテナがあれば並べ、入口も出す', (tester) async {
      await openChooser(tester);

      expect(find.text('実況'), findsOneWidget);
      expect(find.text('アンテナを管理する'), findsOneWidget);
    });
  });
}

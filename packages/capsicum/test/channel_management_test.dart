import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/channel_edit_screen.dart';
import 'package:capsicum/src/ui/screen/channel_management_screen.dart';
import 'package:capsicum/src/ui/widget/channel_actions_sheet.dart';
import 'package:capsicum/src/ui/widget/home_menu.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

/// #1051: チャンネルの管理画面・操作のシート・作成 / 編集。
class _Adapter extends Mock
    implements
        DecentralizedBackendAdapter,
        ChannelSupport,
        ChannelManagementSupport {}

class _DraftFake extends Fake implements ChannelDraft {}

class _AccountNotifier extends AccountManagerNotifier {
  _AccountNotifier(this._account);

  final Account _account;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: [_account], current: _account);
}

const _plain = Channel(id: 'c1', name: 'プリキュア', userId: 'other');
const _mine = Channel(id: 'c2', name: '自作', userId: 'me', description: '説明');

void main() {
  late _Adapter adapter;

  setUpAll(() => registerFallbackValue(_DraftFake()));

  setUp(() {
    adapter = _Adapter();
    when(() => adapter.getFeaturedChannels()).thenAnswer((_) async => [_plain]);
    when(() => adapter.getFollowedChannels()).thenAnswer((_) async => []);
    when(() => adapter.getFavoriteChannels()).thenAnswer((_) async => []);
    when(() => adapter.getOwnedChannels()).thenAnswer((_) async => [_mine]);
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

  /// [home] を開く。`/channels/edit` は積まれた印と結果だけを返す。
  Future<void> pump(WidgetTester tester, Widget home) async {
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => home),
        GoRoute(
          path: '/channels/edit',
          builder: (context, state) => Scaffold(
            body: Text(
              '編集の画面:${state.extra is Channel ? (state.extra as Channel).id : "新規"}',
            ),
          ),
        ),
        GoRoute(
          path: '/channels/manage',
          builder: (_, _) => const Scaffold(body: Text('管理の画面')),
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

  group('管理画面', () {
    testWidgets('4 分類が並び、最初は人気を出す', (tester) async {
      await pump(tester, const ChannelManagementScreen());

      for (final label in ['人気', 'フォロー中', 'お気に入り', '自分の']) {
        expect(find.widgetWithText(Tab, label), findsOneWidget);
      }
      expect(find.text('プリキュア'), findsOneWidget);
    });

    testWidgets('検索すると結果を出し、やめると分類へ戻る', (tester) async {
      when(() => adapter.searchChannels('自')).thenAnswer((_) async => [_mine]);
      await pump(tester, const ChannelManagementScreen());

      await tester.enterText(find.byType(TextField), ' 自 ');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('自作'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);

      await tester.tap(find.byTooltip('検索をやめる'));
      await tester.pumpAndSettle();

      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text('プリキュア'), findsOneWidget);
    });

    testWidgets('検索に当たらなければそう書く', (tester) async {
      when(() => adapter.searchChannels('x')).thenAnswer((_) async => []);
      await pump(tester, const ChannelManagementScreen());

      await tester.enterText(find.byType(TextField), 'x');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('見つかりませんでした'), findsOneWidget);
    });

    testWidgets('＋で作成の画面へ行く', (tester) async {
      await pump(tester, const ChannelManagementScreen());

      await tester.tap(find.byTooltip('新規作成'));
      await tester.pumpAndSettle();

      expect(find.text('編集の画面:新規'), findsOneWidget);
    });

    testWidgets('取得に失敗したら再試行できる', (tester) async {
      when(
        () => adapter.getFeaturedChannels(),
      ).thenThrow(StateError('network'));
      await pump(tester, const ChannelManagementScreen());

      expect(find.text('読み込みに失敗しました'), findsOneWidget);
    });
  });

  group('操作のシート', () {
    Future<void> openSheet(WidgetTester tester, Channel channel) async {
      await pump(
        tester,
        Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => showChannelActions(context, ref, channel),
              child: const Text('開く'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
    }

    testWidgets('フォローしていなければフォローを送る', (tester) async {
      when(() => adapter.followChannel('c1')).thenAnswer((_) async {});
      await openSheet(tester, _plain);

      await tester.tap(find.text('フォロー'));
      await tester.pumpAndSettle();

      verify(() => adapter.followChannel('c1')).called(1);
      expect(find.text('フォローしました'), findsOneWidget);
    });

    testWidgets('状態に応じて解除の側を出して送る', (tester) async {
      when(() => adapter.unfollowChannel('c1')).thenAnswer((_) async {});
      await openSheet(
        tester,
        const Channel(
          id: 'c1',
          name: 'n',
          isFollowing: true,
          isFavorited: true,
          isMuting: true,
        ),
      );

      expect(find.text('お気に入りから外す'), findsOneWidget);
      expect(find.text('ミュート解除'), findsOneWidget);

      await tester.tap(find.text('フォロー解除'));
      await tester.pumpAndSettle();

      verify(() => adapter.unfollowChannel('c1')).called(1);
    });

    testWidgets('お気に入りとミュートを送る', (tester) async {
      when(() => adapter.favoriteChannel('c1')).thenAnswer((_) async {});
      when(() => adapter.muteChannel('c1')).thenAnswer((_) async {});
      await openSheet(tester, _plain);

      await tester.tap(find.text('お気に入りに追加'));
      await tester.pumpAndSettle();
      verify(() => adapter.favoriteChannel('c1')).called(1);

      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ミュート'));
      await tester.pumpAndSettle();
      verify(() => adapter.muteChannel('c1')).called(1);
    });

    testWidgets('⚠ 失敗したら理由を添えて知らせる（成功とは言わない）', (tester) async {
      when(() => adapter.followChannel('c1')).thenThrow(StateError('boom'));
      await openSheet(tester, _plain);

      await tester.tap(find.text('フォロー'));
      await tester.pumpAndSettle();

      expect(find.textContaining('フォローに失敗しました'), findsOneWidget);
      expect(find.text('フォローしました'), findsNothing);
    });

    testWidgets('⚠ 編集は作成者にだけ出す', (tester) async {
      await openSheet(tester, _plain);

      expect(find.text('編集'), findsNothing);
    });

    testWidgets('作成者なら編集の画面へ行く', (tester) async {
      await openSheet(tester, _mine);

      await tester.tap(find.text('編集'));
      await tester.pumpAndSettle();

      expect(find.text('編集の画面:c2'), findsOneWidget);
    });
  });

  group('作成 / 編集の画面', () {
    /// 編集の画面を積んで開く。閉じたときの結果が返り値に入る。
    Future<List<bool?>> pushEdit(
      WidgetTester tester, {
      Channel? channel,
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
                      builder: (_) => ChannelEditScreen(channel: channel),
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

    testWidgets('名前が空なら送らない', (tester) async {
      await pump(tester, const ChannelEditScreen());

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('名前を入れてください'), findsOneWidget);
      verifyNever(() => adapter.createChannel(any()));
    });

    testWidgets('入力したものを作成で送る', (tester) async {
      when(() => adapter.createChannel(any())).thenAnswer((_) async => _plain);
      final results = await pushEdit(tester);

      await tester.enterText(find.byType(TextField).first, ' 名前 ');
      await tester.tap(find.text('センシティブなチャンネル'));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(results, [true], reason: '閉じて、一覧へ取り直しを促す');
      final draft =
          verify(() => adapter.createChannel(captureAny())).captured.single
              as ChannelDraft;
      expect(draft.name, '名前');
      expect(draft.isSensitive, isTrue);
      expect(draft.allowRenoteToExternal, isTrue);
    });

    testWidgets('編集は今の値を出し、そのチャンネルへ送る', (tester) async {
      when(
        () => adapter.updateChannel('c2', any()),
      ).thenAnswer((_) async => _mine);
      final results = await pushEdit(tester, channel: _mine);

      expect(find.text('自作'), findsOneWidget);
      expect(find.text('説明'), findsWidgets);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      verify(() => adapter.updateChannel('c2', any())).called(1);
      expect(results, [true]);
    });

    testWidgets('⚠ 失敗したら入力を残して留まる', (tester) async {
      when(() => adapter.createChannel(any())).thenThrow(StateError('boom'));
      await pump(tester, const ChannelEditScreen());

      await tester.enterText(find.byType(TextField).first, '残す名前');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.textContaining('チャンネルの保存に失敗しました'), findsOneWidget);
      expect(find.text('残す名前'), findsOneWidget);
      expect(find.byType(ChannelEditScreen), findsOneWidget);
    });
  });

  group('ドロワーのチューザ', () {
    Future<void> openChooser(WidgetTester tester) async {
      await pump(
        tester,
        Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => showChannelList(context, ref),
              child: const Text('開く'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
    }

    testWidgets('⚠⚠ フォローが 0 件でも開いて、管理の画面へ行ける', (tester) async {
      await openChooser(tester);

      expect(find.text('フォロー中のチャンネルはありません'), findsOneWidget);
      await tester.tap(find.text('チャンネルを探す・管理する'));
      await tester.pumpAndSettle();

      expect(find.text('管理の画面'), findsOneWidget);
    });

    testWidgets('フォロー中があれば並べ、入口も出す', (tester) async {
      when(
        () => adapter.getFollowedChannels(),
      ).thenAnswer((_) async => [_plain]);
      await openChooser(tester);

      expect(find.text('プリキュア'), findsOneWidget);
      expect(find.text('フォロー中のチャンネルはありません'), findsNothing);
      expect(find.text('チャンネルを探す・管理する'), findsOneWidget);
    });
  });
}

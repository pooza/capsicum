import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/deck_provider.dart';
import 'package:capsicum/src/ui/widget/desktop_menu_model.dart';
import 'package:capsicum/src/ui/widget/home_menu.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1170: デスクトップメニューをデッキ表示に合わせて切り替える
/// （`docs/deck-ui-plan.md` 決定済み事項 11）。
///
/// ⚠⚠ **メニューバーは ShellRoute に常駐していて、デッキでも同じものが出る。**
/// そのままだと「表示 > タブ」や「他アカウントへ切り替え」が**選んだ瞬間に
/// デッキを抜ける**。⚠ 丸ごと隠す案は採らない（macOS の「終了」まで消える）ので、
/// **差し替えるのは 3 か所だけ**であることをここで固定する。
class _Capabilities extends Mock implements AdapterCapabilities {
  @override
  Set<TimelineType> get supportedTimelines => {
    TimelineType.home,
    TimelineType.local,
  };
}

class _Adapter extends Mock implements DecentralizedBackendAdapter {
  @override
  AdapterCapabilities get capabilities => _Capabilities();
}

Account _account(String username) => Account(
  key: AccountKey(
    type: BackendType.misskey,
    host: 'misskey.example',
    username: username,
  ),
  adapter: _Adapter(),
  user: User(id: username, username: username, displayName: '$username さん'),
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

  /// メニューモデルを組み立てて返す。
  ///
  /// [inDeck] はデッキ画面が開いている状態（`mountedDeckCountProvider` > 0）。
  /// [registerRefresh] を渡すと、そのカラム id に再読み込みが登録済みになる。
  Future<List<MenuSubmenuEntry>> buildModel(
    WidgetTester tester, {
    bool inDeck = false,
    List<String> columnIds = const ['a', 'b'],
    List<String> usernames = const ['me', 'other'],
    String? registerRefresh,
    List<String> composeCalls = const [],
    List<String> revealed = const [],
    List<String> sheetOpened = const [],
  }) async {
    SharedPreferences.setMockInitialValues({
      'deck_columns': [
        for (final id in columnIds)
          '$id|misskey://me@misskey.example|hashtag:$id',
      ],
    });
    initSharedPreferencesCache(await SharedPreferences.getInstance());

    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(
          () => _TestAccountNotifier([for (final u in usernames) _account(u)]),
        ),
      ],
    );
    addTearDown(container.dispose);

    if (inDeck) {
      container.read(mountedDeckCountProvider.notifier).state = 1;
      container.read(deckMenuActionsProvider.notifier).state = DeckMenuActions(
        revealAndFocus: revealed.add,
        openCompose: () => composeCalls.add('compose'),
        openColumnsSheet: () => sheetOpened.add('sheet'),
      );
    }
    if (registerRefresh != null) {
      container
          .read(deckColumnRefreshProvider.notifier)
          .register(registerRefresh, () async {});
    }

    late List<MenuSubmenuEntry> model;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              final state = ref.watch(accountManagerProvider);
              model = buildDesktopMenuModel(
                context,
                ref,
                state.current,
                state,
                0,
              );
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return model;
  }

  List<MenuEntry> childrenOf(List<MenuSubmenuEntry> model, String label) =>
      model.firstWhere((m) => m.label == label).children;

  MenuActionEntry? actionNamed(List<MenuEntry> children, String label) =>
      children
          .whereType<MenuActionEntry>()
          .where((a) => a.label == label)
          .firstOrNull;

  MenuSubmenuEntry? submenuNamed(List<MenuEntry> children, String label) =>
      children
          .whereType<MenuSubmenuEntry>()
          .where((s) => s.label == label)
          .firstOrNull;

  group('表示 > タブ / カラム', () {
    testWidgets('前提: デッキの外では「タブ」が出て「カラム」は出ない', (tester) async {
      final view = childrenOf(await buildModel(tester), '表示');

      expect(submenuNamed(view, 'タブ'), isNotNull);
      expect(submenuNamed(view, 'カラム'), isNull);
      expect(actionNamed(view, 'デッキ表示に切り替え'), isNotNull);
    });

    testWidgets('⚠⚠ デッキ中は「タブ」を出さない（選ぶとデッキを抜ける）', (tester) async {
      final view = childrenOf(await buildModel(tester, inDeck: true), '表示');

      expect(submenuNamed(view, 'タブ'), isNull);
      expect(actionNamed(view, 'タブ表示に切り替え'), isNotNull);
    });

    testWidgets('⚠ デッキ中は「カラム」を出し、見出しと同じ「タブ名 · 表示名」で並べる', (tester) async {
      final view = childrenOf(await buildModel(tester, inDeck: true), '表示');
      final columns = submenuNamed(view, 'カラム')!.children;

      final labels = columns
          .whereType<MenuActionEntry>()
          .map((a) => a.label)
          .toList();
      expect(labels, ['#a · me さん', '#b · me さん', 'カラムを編集…']);
    });

    testWidgets('⚠ フォーカス中のカラムに ✓ が付く', (tester) async {
      final view = childrenOf(await buildModel(tester, inDeck: true), '表示');
      final columns = submenuNamed(view, 'カラム')!.children;

      expect(actionNamed(columns, '#a · me さん')!.checked, isTrue);
      expect(actionNamed(columns, '#b · me さん')!.checked, isFalse);
      // 「カラムを編集…」はトグルではないので checked を持たない。
      expect(actionNamed(columns, 'カラムを編集…')!.checked, isNull);
    });

    testWidgets('カラムを選ぶとそこへ送ってフォーカスを移す', (tester) async {
      final revealed = <String>[];
      final view = childrenOf(
        await buildModel(tester, inDeck: true, revealed: revealed),
        '表示',
      );
      final columns = submenuNamed(view, 'カラム')!.children;

      actionNamed(columns, '#b · me さん')!.onSelected!();

      expect(revealed, ['b']);
    });

    testWidgets('「カラムを編集…」はシートを開く', (tester) async {
      final opened = <String>[];
      final view = childrenOf(
        await buildModel(tester, inDeck: true, sheetOpened: opened),
        '表示',
      );
      final columns = submenuNamed(view, 'カラム')!.children;

      actionNamed(columns, 'カラムを編集…')!.onSelected!();

      expect(opened, ['sheet']);
    });

    testWidgets('⚠ 列が空でも「カラムを編集…」は出す（そこからしか足せない）', (tester) async {
      final view = childrenOf(
        await buildModel(tester, inDeck: true, columnIds: const []),
        '表示',
      );
      final columns = submenuNamed(view, 'カラム')!.children;

      expect(actionNamed(columns, 'カラムを編集…'), isNotNull);
    });
  });

  group('表示 > タイムラインを更新 (#1157)', () {
    testWidgets('前提: デッキの外では常に押せる', (tester) async {
      final view = childrenOf(await buildModel(tester), '表示');

      expect(actionNamed(view, 'タイムラインを更新')!.onSelected, isNotNull);
    });

    testWidgets('⚠⚠ デッキ中にフォーカス中のカラムが更新の口を持たなければ無効', (tester) async {
      final view = childrenOf(await buildModel(tester, inDeck: true), '表示');

      expect(
        actionNamed(view, 'タイムラインを更新')!.onSelected,
        isNull,
        reason: '⚠ 押せるのに何も起きないほうが分かりにくい',
      );
    });

    testWidgets('フォーカス中のカラムが登録していれば押せる', (tester) async {
      final view = childrenOf(
        await buildModel(tester, inDeck: true, registerRefresh: 'a'),
        '表示',
      );

      expect(actionNamed(view, 'タイムラインを更新')!.onSelected, isNotNull);
    });

    testWidgets('⚠ 登録が別のカラムのものなら無効（フォーカス中のぶんだけ見る）', (tester) async {
      final view = childrenOf(
        await buildModel(tester, inDeck: true, registerRefresh: 'b'),
        '表示',
      );

      expect(actionNamed(view, 'タイムラインを更新')!.onSelected, isNull);
    });

    testWidgets('⚠⚠ 「すべてのカラムを更新」は置かない', (tester) async {
      final view = childrenOf(await buildModel(tester, inDeck: true), '表示');

      // 2026-09-26 pooza: ストリーミングで流れてくるので全部を取り直す状況が無く、
      // カラム数ぶん REST が一斉に走るのも避けたい。
      expect(actionNamed(view, 'すべてのカラムを更新'), isNull);
    });
  });

  group('アカウント', () {
    testWidgets('前提: デッキの外では他アカウントへ切り替えられる', (tester) async {
      final account = childrenOf(await buildModel(tester), 'アカウント');

      expect(actionNamed(account, '@other@misskey.example'), isNotNull);
    });

    testWidgets('⚠⚠ デッキ中は切り替えを隠す（デッキを抜けるため）', (tester) async {
      final account = childrenOf(
        await buildModel(tester, inDeck: true),
        'アカウント',
      );

      expect(actionNamed(account, '@other@misskey.example'), isNull);
    });

    testWidgets('⚠ プロフィール・追加・ログアウトは残す', (tester) async {
      final account = childrenOf(
        await buildModel(tester, inDeck: true),
        'アカウント',
      );

      expect(actionNamed(account, 'プロフィール'), isNotNull);
      expect(actionNamed(account, 'アカウントを追加'), isNotNull);
      expect(actionNamed(account, 'ログアウト'), isNotNull);
    });
  });

  group('移動 > 新規投稿 (⌘N)', () {
    testWidgets('⚠⚠ デッキ中はデッキ画面が登録したものを呼ぶ（カラムのアカウントで投稿する）', (tester) async {
      final calls = <String>[];
      final move = childrenOf(
        await buildModel(tester, inDeck: true, composeCalls: calls),
        '移動',
      );

      actionNamed(move, '新規投稿')!.onSelected!();

      expect(calls, [
        'compose',
      ], reason: '⚠ ルートのスコープで push すると現在のアカウントから投稿される (#1149)');
    });

    testWidgets('前提: デッキの外では従来どおり（登録を呼ばない）', (tester) async {
      final calls = <String>[];
      final move = childrenOf(
        await buildModel(tester, composeCalls: calls),
        '移動',
      );

      expect(actionNamed(move, '新規投稿')!.onSelected, isNotNull);
      expect(calls, isEmpty);
    });
  });

  testWidgets('⚠ メニューを丸ごと隠したりはしない（capsicum / 編集が残る）', (tester) async {
    final model = await buildModel(tester, inDeck: true);

    expect(model.map((m) => m.label), containsAll(['capsicum', '編集', '表示']));
  });
}

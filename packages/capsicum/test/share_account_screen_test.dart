import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/share_account_screen.dart';
import 'package:capsicum/src/ui/widget/inline_custom_emoji.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1348: ナウプレの共有で、投稿するアカウントを選ぶ。
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

class _Mulukhiya extends Mock implements MulukhiyaService {
  _Mulukhiya({required this.resolves});

  final bool resolves;

  @override
  bool get nowplayingUrlResolverEnabled => resolves;
}

class _AccountNotifier extends AccountManagerNotifier {
  _AccountNotifier(this._accounts);

  final List<Account> _accounts;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: _accounts, current: _accounts.first);

  @override
  void switchAccount(Account account, {bool clearUnread = true}) {
    switched = account;
    state = state.copyWith(current: account);
  }

  Account? switched;
}

void main() {
  setUp(() {
    // EmojiText が絵文字の大きさを読む。
    SharedPreferences.setMockInitialValues({});
  });

  Account account(
    String name, {
    String? displayName,
    Map<String, String> emojis = const {},
  }) => Account(
    key: AccountKey(
      type: BackendType.mastodon,
      host: '$name.example',
      username: name,
    ),
    adapter: _Adapter(),
    user: User(
      id: name,
      username: name,
      displayName: displayName,
      emojis: emojis,
    ),
    userSecret: const UserSecret(accessToken: 'token'),
  );

  // #1361: 選ぶ前に URL を送る先を、現在のアカウントに寄せる。
  group('shareResolverAccount', () {
    Account withResolver(String name, {required bool resolves}) {
      final a = account(name);
      return Account(
        key: a.key,
        adapter: a.adapter,
        user: a.user,
        userSecret: a.userSecret,
        mulukhiya: _Mulukhiya(resolves: resolves),
      );
    }

    test('現在のアカウントが引けるなら、一覧の先頭ではなくそれを借りる', () {
      final first = withResolver('first', resolves: true);
      final current = withResolver('current', resolves: true);

      final picked = shareResolverAccount(
        AccountManagerState(accounts: [first, current], current: current),
      );

      expect(picked?.key, current.key);
    });

    test('現在のアカウントが引けなければ、引ける別のアカウント', () {
      final current = withResolver('current', resolves: false);
      final other = withResolver('other', resolves: true);

      final picked = shareResolverAccount(
        AccountManagerState(accounts: [current, other], current: current),
      );

      expect(picked?.key, other.key);
    });

    test('どれも引けなければ null（共有のまま出す）', () {
      final current = account('current');

      expect(
        shareResolverAccount(
          AccountManagerState(accounts: [current], current: current),
        ),
        isNull,
      );
    });
  });

  test('shareDestination: 1 つなら今までどおり、2 つ以上で選ばせる', () {
    expect(shareDestination(1), '/compose');
    expect(shareDestination(2), '/share/account');
  });

  Future<_AccountNotifier> pump(
    WidgetTester tester, {
    String sharedText = 'https://music.example/1',
    List<Account>? accounts,
  }) async {
    final notifier = _AccountNotifier(accounts ?? [account('a'), account('b')]);
    final router = GoRouter(
      initialLocation: '/share',
      routes: [
        GoRoute(
          path: '/share',
          builder: (_, _) => ShareAccountScreen(sharedText: sharedText),
        ),
        GoRoute(
          path: '/compose',
          builder: (_, state) =>
              Scaffold(body: Text('投稿:${(state.extra! as Map)['sharedText']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [accountManagerProvider.overrideWith(() => notifier)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return notifier;
  }

  testWidgets('何のための一覧かと、共有したものが分かる', (tester) async {
    await pump(tester);

    expect(find.text('ナウプレを投稿するアカウントを選ぶ'), findsOneWidget);
    expect(find.byIcon(Icons.music_note), findsOneWidget);
    expect(find.text('https://music.example/1'), findsOneWidget);
    expect(find.textContaining('共有は取り消されます'), findsOneWidget);
  });

  testWidgets('⚠ 表示名のカスタム絵文字を :shortcode: のまま出さない', (tester) async {
    await pump(
      tester,
      accounts: [
        account(
          'a',
          displayName: 'ぷーざ :blobcat:',
          emojis: {'blobcat': 'https://a.example/emoji/blobcat.png'},
        ),
        account('b'),
      ],
    );

    expect(find.byType(InlineCustomEmoji), findsOneWidget);
    // ⚠ textContaining では見ない。テストでは画像が 400 で落ち、読み込めない
    // 絵文字の代わりに出す `:blobcat:` が当たる。
    expect(find.text('ぷーざ :blobcat:'), findsNothing);
  });

  testWidgets('今のアカウントに印が付く', (tester) async {
    await pump(tester);

    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'a'),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
  });

  testWidgets('選ぶとそのアカウントで投稿フォームへ本文を渡す', (tester) async {
    final notifier = await pump(tester);

    await tester.tap(find.widgetWithText(ListTile, 'b'));
    await tester.pumpAndSettle();

    expect(notifier.switched?.key.username, 'b');
    expect(find.text('投稿:https://music.example/1'), findsOneWidget);
  });
}

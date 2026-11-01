import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/avatar_decoration_screen.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1349: アイコンデコレーションの付け外し。
class _Adapter extends Mock
    implements DecentralizedBackendAdapter, AvatarDecorationSupport {}

class _AccountNotifier extends AccountManagerNotifier {
  _AccountNotifier(this._accounts, this._current);

  final List<Account> _accounts;
  final Account _current;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: _accounts, current: _current);
}

const _pumpkin = AvatarDecorationOption(
  id: 'a',
  name: 'かぼちゃ',
  url: 'https://example.invalid/a.png',
);

void main() {
  late _Adapter adapter;

  Account account(
    String name, {
    List<AvatarDecoration> decorations = const [],
  }) => Account(
    key: AccountKey(
      type: BackendType.misskey,
      host: 'misskey.example',
      username: name,
    ),
    adapter: adapter,
    user: User(id: name, username: name, avatarDecorations: decorations),
    userSecret: const UserSecret(accessToken: 'token'),
  );

  setUp(() {
    adapter = _Adapter();
    when(
      () => adapter.getAvatarDecorationOptions(),
    ).thenAnswer((_) async => [_pumpkin]);
  });

  Future<ProviderContainer> pump(WidgetTester tester, Account current) async {
    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(
          () => _AccountNotifier([current], current),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AvatarDecorationScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('押すと付き、保存の応答をアカウントへ反映する', (tester) async {
    final me = account('me');
    when(() => adapter.attachAvatarDecoration('a')).thenAnswer(
      (_) async => const User(
        id: 'me',
        username: 'me',
        avatarDecorations: [
          AvatarDecoration(id: 'a', url: 'https://example.invalid/a.png'),
        ],
      ),
    );
    final container = await pump(tester, me);

    await tester.tap(find.text('かぼちゃ'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(
      container
          .read(accountManagerProvider)
          .current!
          .user
          .avatarDecorations
          .single
          .id,
      'a',
    );
  });

  testWidgets('付いているものを押すと外す', (tester) async {
    final me = account(
      'me',
      decorations: const [
        AvatarDecoration(id: 'a', url: 'https://example.invalid/a.png'),
      ],
    );
    when(
      () => adapter.detachAvatarDecoration('a'),
    ).thenAnswer((_) async => const User(id: 'me', username: 'me'));
    await pump(tester, me);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    await tester.tap(find.text('かぼちゃ'));
    await tester.pumpAndSettle();

    verify(() => adapter.detachAvatarDecoration('a')).called(1);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('⚠⚠ 黙って落とされたら、付いたように見せない', (tester) async {
    when(
      () => adapter.attachAvatarDecoration('a'),
    ).thenThrow(const AvatarDecorationRejected());
    await pump(tester, account('me'));

    await tester.tap(find.text('かぼちゃ'));
    await tester.pumpAndSettle();

    expect(find.text('「かぼちゃ」はこのアカウントでは使えません'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  test('updateUserOf: 指定のアカウントだけを書き換える', () {
    final a = account('a');
    final b = account('b');
    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(() => _AccountNotifier([a, b], a)),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(accountManagerProvider.notifier)
        .updateUserOf(b.key, const User(id: 'b', username: 'renamed'));

    final state = container.read(accountManagerProvider);
    expect(state.current!.user.username, 'a', reason: '現在のアカウントに書かない');
    expect(state.accounts.last.user.username, 'renamed');
  });
}

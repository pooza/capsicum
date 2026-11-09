import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/avatar_decoration_screen.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
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
    when(() => adapter.getAvatarDecorationLimit()).thenAnswer((_) async => 3);
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
    ).thenThrow(const AvatarDecorationRejected(User(id: 'me', username: 'me')));
    await pump(tester, account('me'));

    await tester.tap(find.text('かぼちゃ'));
    await tester.pumpAndSettle();

    expect(find.text('「かぼちゃ」はこのアカウントでは使えません'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('⚠ 保存の回数制限（i/update は 1 時間 20 回）は専用の文言で知らせる', (tester) async {
    final options = RequestOptions(path: '/api/i/update');
    when(() => adapter.attachAvatarDecoration('a')).thenThrow(
      DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: options,
          statusCode: 429,
          data: {
            'error': {'code': 'RATE_LIMIT_EXCEEDED'},
          },
        ),
      ),
    );
    await pump(tester, account('me'));

    await tester.tap(find.text('かぼちゃ'));
    await tester.pumpAndSettle();

    expect(find.textContaining('短い間に保存しすぎました'), findsOneWidget);
    expect(find.textContaining('保存できませんでした'), findsNothing);
  });

  // #1359: 位置・角度・反転の調整と、残りの数。
  testWidgets('一覧の上に、あといくつ付けられるかを出す', (tester) async {
    await pump(
      tester,
      account(
        'me',
        decorations: const [
          AvatarDecoration(id: 'a', url: 'https://example.invalid/a.png'),
        ],
      ),
    );

    expect(find.text('あと 2 個付けられます（1 / 3）'), findsOneWidget);
  });

  testWidgets('付いていないものには調整のボタンを出さない', (tester) async {
    await pump(tester, account('me'));

    expect(find.byIcon(Icons.tune), findsNothing);
  });

  testWidgets('調整して保存すると、変えた値とそれ以外の今の値を送る', (tester) async {
    const current = AvatarDecoration(
      id: 'a',
      url: 'https://example.invalid/a.png',
      angle: 0.1,
      offsetX: 0.05,
      offsetY: -0.05,
    );
    when(
      () => adapter.adjustAvatarDecoration(
        'a',
        angle: any(named: 'angle'),
        flipH: any(named: 'flipH'),
        offsetX: any(named: 'offsetX'),
        offsetY: any(named: 'offsetY'),
      ),
    ).thenAnswer(
      (_) async => const User(
        id: 'me',
        username: 'me',
        avatarDecorations: [
          AvatarDecoration(
            id: 'a',
            url: 'https://example.invalid/a.png',
            angle: 0.1,
            flipH: true,
            offsetX: 0.05,
            offsetY: -0.05,
          ),
        ],
      ),
    );
    final container = await pump(
      tester,
      account('me', decorations: const [current]),
    );

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('左右反転'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    verify(
      () => adapter.adjustAvatarDecoration(
        'a',
        angle: 0.1,
        flipH: true,
        offsetX: 0.05,
        offsetY: -0.05,
      ),
    ).called(1);
    expect(
      container
          .read(accountManagerProvider)
          .current!
          .user
          .avatarDecorations
          .single
          .flipH,
      isTrue,
    );
  });

  testWidgets('キャンセルしたら保存しない', (tester) async {
    await pump(
      tester,
      account(
        'me',
        decorations: const [
          AvatarDecoration(id: 'a', url: 'https://example.invalid/a.png'),
        ],
      ),
    );

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();

    verifyNever(
      () => adapter.adjustAvatarDecoration(
        any(),
        angle: any(named: 'angle'),
        flipH: any(named: 'flipH'),
        offsetX: any(named: 'offsetX'),
        offsetY: any(named: 'offsetY'),
      ),
    );
  });

  group('残りの数の文言', () {
    test('上限が読めなければ出さない', () {
      expect(avatarDecorationRemainingLabel(attached: 1, limit: null), isNull);
    });

    test('⚠ 上限が 1 なら、入れ替わることを言う（「あと 0 個」と出さない）', () {
      expect(
        avatarDecorationRemainingLabel(attached: 1, limit: 1),
        '付けられるのは 1 個です。ほかを選ぶと入れ替わります',
      );
    });

    test('上限が 0 なら付けられない', () {
      expect(
        avatarDecorationRemainingLabel(attached: 0, limit: 0),
        'このアカウントではデコレーションを付けられません',
      );
    });

    test('上限を超えて付いていても、負の数を出さない', () {
      expect(
        avatarDecorationRemainingLabel(attached: 5, limit: 3),
        'あと 0 個付けられます（5 / 3）',
      );
    });
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

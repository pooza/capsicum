// #1398: 投稿の自動処理（モロヘイヤのハンドラー）を、自分の投稿について切り替える。
import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/mulukhiya_handlers_screen.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Adapter extends Mock implements DecentralizedBackendAdapter {}

class _Mulukhiya extends Mock implements MulukhiyaService {}

const _tagHandler = MulukhiyaUserHandler(
  name: 'default_tag',
  label: 'デフォルトタグ',
  description: '投稿にデフォルトのハッシュタグを付与します',
  toggleable: false,
  disabled: false,
);

const _urlHandler = MulukhiyaUserHandler(
  name: 'url_normalize',
  label: 'URL の正規化',
  toggleable: true,
  disabled: false,
);

Account _account(MulukhiyaService mulukhiya) => Account(
  key: const AccountKey(
    type: BackendType.mastodon,
    host: 'mstdn.example',
    username: 'me',
  ),
  adapter: _Adapter(),
  user: const User(id: '1', username: 'me'),
  userSecret: const UserSecret(accessToken: 'tok'),
  mulukhiya: mulukhiya,
);

void main() {
  late _Mulukhiya mulukhiya;

  setUp(() {
    mulukhiya = _Mulukhiya();
    when(() => mulukhiya.userHandlerConfigEnabled).thenReturn(true);
    when(
      () => mulukhiya.getUserHandlers(accessToken: any(named: 'accessToken')),
    ).thenAnswer((_) async => [_tagHandler, _urlHandler]);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentAccountProvider.overrideWithValue(_account(mulukhiya)),
        ],
        child: const MaterialApp(home: MulukhiyaHandlersScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  SwitchListTile tile(WidgetTester tester, String name) => tester
      .widget<SwitchListTile>(find.byKey(ValueKey('mulukhiya-handler-$name')));

  testWidgets('一覧を並べ、⚠ 切り替えられないものは隠さず無効にする', (tester) async {
    await pump(tester);

    expect(find.text('デフォルトタグ'), findsOneWidget);
    expect(find.text('URL の正規化'), findsOneWidget);
    expect(tile(tester, 'default_tag').onChanged, isNull);
    expect(find.textContaining('このサーバーでは切り替えられません'), findsOneWidget);
    expect(tile(tester, 'url_normalize').onChanged, isNotNull);
    expect(tile(tester, 'url_normalize').value, isTrue, reason: 'オン＝無効でない');
  });

  testWidgets('オフにすると disable: true を送り、スイッチがオフになる', (tester) async {
    when(
      () => mulukhiya.setUserHandlerDisabled(
        accessToken: any(named: 'accessToken'),
        handler: any(named: 'handler'),
        disabled: any(named: 'disabled'),
      ),
    ).thenAnswer((_) async => true);
    await pump(tester);

    await tester.tap(
      find.byKey(const ValueKey('mulukhiya-handler-url_normalize')),
    );
    await tester.pumpAndSettle();

    verify(
      () => mulukhiya.setUserHandlerDisabled(
        accessToken: 'tok',
        handler: 'url_normalize',
        disabled: true,
      ),
    ).called(1);
    expect(tile(tester, 'url_normalize').value, isFalse);
  });

  testWidgets('⚠ 失敗したらスイッチを戻して知らせる', (tester) async {
    when(
      () => mulukhiya.setUserHandlerDisabled(
        accessToken: any(named: 'accessToken'),
        handler: any(named: 'handler'),
        disabled: any(named: 'disabled'),
      ),
    ).thenThrow(StateError('offline'));
    await pump(tester);

    await tester.tap(
      find.byKey(const ValueKey('mulukhiya-handler-url_normalize')),
    );
    await tester.pumpAndSettle();

    expect(tile(tester, 'url_normalize').value, isTrue, reason: '送る前の値へ戻す');
    expect(find.text('切り替えられませんでした'), findsOneWidget);
  });

  testWidgets('フラグが無いサーバーでは一覧を取りに行かない', (tester) async {
    when(() => mulukhiya.userHandlerConfigEnabled).thenReturn(false);
    await pump(tester);

    verifyNever(
      () => mulukhiya.getUserHandlers(accessToken: any(named: 'accessToken')),
    );
    expect(find.text('切り替えられる処理はありません。'), findsOneWidget);
  });
}

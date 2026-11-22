// #1398: 投稿の自動処理（モロヘイヤのハンドラー）を、自分の投稿について切り替える。
import 'dart:async';

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

const _spotifyHandler = MulukhiyaUserHandler(
  name: 'spotify_url',
  label: 'Spotify の URL',
  toggleable: true,
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
    ).thenAnswer((_) async => [_tagHandler, _urlHandler, _spotifyHandler]);
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

  // ⚠ 戻す先は一覧を取った時点の値ではなく、直前に成功した値（リリース前
  // レビュー・Codex P2）。
  testWidgets('⚠ 成功のあとの切り替えに失敗したら、成功した値へ戻す', (tester) async {
    var calls = 0;
    when(
      () => mulukhiya.setUserHandlerDisabled(
        accessToken: any(named: 'accessToken'),
        handler: any(named: 'handler'),
        disabled: any(named: 'disabled'),
      ),
    ).thenAnswer((_) async {
      if (++calls == 1) return true;
      throw StateError('offline');
    });
    await pump(tester);
    final finder = find.byKey(
      const ValueKey('mulukhiya-handler-url_normalize'),
    );

    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(tile(tester, 'url_normalize').value, isFalse, reason: '前提: オフにできた');

    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(
      tile(tester, 'url_normalize').value,
      isFalse,
      reason: 'サーバーはオフのまま。一覧の値（オン）へ戻さない',
    );
  });

  // ⚠ モロヘイヤは利用者の設定を「読んで足して書く」で保存するので、別々の
  // 項目でも並べて送ると片方が消える。
  testWidgets('⚠ 送っている間は、ほかのスイッチも押せない', (tester) async {
    final pending = Completer<bool>();
    when(
      () => mulukhiya.setUserHandlerDisabled(
        accessToken: any(named: 'accessToken'),
        handler: any(named: 'handler'),
        disabled: any(named: 'disabled'),
      ),
    ).thenAnswer((_) => pending.future);
    await pump(tester);

    await tester.tap(
      find.byKey(const ValueKey('mulukhiya-handler-url_normalize')),
    );
    await tester.pump();
    expect(tile(tester, 'spotify_url').onChanged, isNull);

    pending.complete(true);
    await tester.pumpAndSettle();
    expect(tile(tester, 'spotify_url').onChanged, isNotNull);
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

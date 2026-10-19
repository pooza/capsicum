import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/posting_defaults_screen.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1210: サーバー側の投稿の既定の画面。
class _Adapter extends Mock
    implements DecentralizedBackendAdapter, PostingDefaultsSupport {
  ({PostScope? scope, bool? sensitive, String? language, String? quote})? sent;

  @override
  Future<User> updatePostingDefaults({
    PostScope? scope,
    bool? sensitive,
    String? language,
    String? quotePolicy,
  }) async {
    sent = (
      scope: scope,
      sensitive: sensitive,
      language: language,
      quote: quotePolicy,
    );
    return User(
      id: 'me',
      username: 'me',
      defaultScope: scope,
      defaultSensitive: sensitive,
      defaultLanguage: language,
      defaultQuotePolicy: quotePolicy,
    );
  }
}

const _key = AccountKey(
  type: BackendType.mastodon,
  host: 'mastodon.example',
  username: 'me',
);

class _Accounts extends AccountManagerNotifier {
  _Accounts(this.account);

  final Account account;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: [account], current: account);
}

void main() {
  Future<(ProviderContainer, _Adapter)> pump(
    WidgetTester tester, {
    required User user,
  }) async {
    final adapter = _Adapter();
    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(
          () => _Accounts(
            Account(
              key: _key,
              adapter: adapter,
              user: user,
              userSecret: const UserSecret(accessToken: 'token'),
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PostingDefaultsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return (container, adapter);
  }

  testWidgets('今の既定を出し、変えた値で保存して手元の User も差し替える', (tester) async {
    final (container, adapter) = await pump(
      tester,
      user: const User(
        id: 'me',
        username: 'me',
        defaultScope: PostScope.public,
        defaultSensitive: false,
        defaultLanguage: 'ja',
        defaultQuotePolicy: 'public',
      ),
    );

    await tester.tap(find.text('フォロワー'));
    await tester.ensureVisible(find.text('許可しない'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('許可しない'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(adapter.sent?.scope, PostScope.followersOnly);
    expect(adapter.sent?.language, 'ja', reason: '触っていない値はそのまま送る');
    expect(adapter.sent?.quote, 'nobody');
    expect(
      container.read(currentAccountProvider)?.user.defaultScope,
      PostScope.followersOnly,
      reason: '次に開く投稿フォームが新しい既定で開くように',
    );
  });

  testWidgets('⚠⚠ フォロワーのみなら、引用は「許可しない」に寄せて保存する（Web と同じ・#1304）', (tester) async {
    final (_, adapter) = await pump(
      tester,
      user: const User(
        id: 'me',
        username: 'me',
        defaultScope: PostScope.public,
        defaultQuotePolicy: 'public',
      ),
    );

    await tester.tap(find.text('フォロワー'));
    await tester.pumpAndSettle();
    expect(find.text('フォロワーのみの投稿は、引用を許可できません。'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(adapter.sent?.scope, PostScope.followersOnly);
    expect(adapter.sent?.quote, 'nobody', reason: '「誰でも」のまま送らない');
  });

  testWidgets('公開範囲を戻したら、選んでいた引用の許可に戻る', (tester) async {
    final (_, adapter) = await pump(
      tester,
      user: const User(
        id: 'me',
        username: 'me',
        defaultScope: PostScope.public,
        defaultQuotePolicy: 'followers',
      ),
    );

    await tester.tap(find.text('フォロワー'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('公開'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(adapter.sent?.quote, 'followers');
  });

  test('effectiveDefaultQuotePolicy', () {
    expect(
      effectiveDefaultQuotePolicy(PostScope.followersOnly, 'public'),
      'nobody',
    );
    expect(effectiveDefaultQuotePolicy(PostScope.public, 'public'), 'public');
    expect(
      effectiveDefaultQuotePolicy(PostScope.unlisted, 'followers'),
      'followers',
    );
    expect(
      effectiveDefaultQuotePolicy(PostScope.followersOnly, null),
      isNull,
      reason: '引用の許可を返さないサーバーには送らない',
    );
  });

  testWidgets('⚠ 9 言語の外の既定（it）も、選択肢から消さずにそのまま送る', (tester) async {
    final (_, adapter) = await pump(
      tester,
      user: const User(id: 'me', username: 'me', defaultLanguage: 'it'),
    );

    expect(find.text('it'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(adapter.sent?.language, 'it');
  });

  testWidgets('引用の許可を返さないサーバー（4.5 より前）では、その節を出さない', (tester) async {
    await pump(
      tester,
      user: const User(id: 'me', username: 'me'),
    );

    expect(find.text('引用の許可'), findsNothing);
    expect(find.text('公開範囲'), findsOneWidget);
  });
}

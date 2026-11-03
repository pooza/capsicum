import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/deck_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/service/post_account_idle_tracker.dart';
import 'package:capsicum/src/ui/widget/simple_post_bar.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Adapter extends Mock implements DecentralizedBackendAdapter {}

class _AccountNotifier extends AccountManagerNotifier {
  _AccountNotifier(this._accounts);

  final List<Account> _accounts;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: _accounts, current: _accounts.first);
}

class _IdleConfirm extends ConfirmPostAccountAfterIdleNotifier {
  _IdleConfirm(this._on);

  final bool _on;

  @override
  bool build() => _on;
}

/// #1306: 簡易投稿バーから送るときの、投稿先の確認と「投稿前に確認する」の重なり。
void main() {
  late _Adapter adapter;

  setUpAll(() => registerFallbackValue(const PostDraft()));

  setUp(() async {
    // 「投稿前に確認する」はオン。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'confirm_before_post': true,
    });
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    postAccountIdleTracker.reset();
    adapter = _Adapter();
    when(() => adapter.postStatus(any())).thenAnswer((_) async => null);
  });

  Account account(String name) => Account(
    key: AccountKey(
      type: BackendType.mastodon,
      host: '$name.example',
      username: name,
    ),
    adapter: adapter,
    user: User(id: name, username: name),
    userSecret: const UserSecret(accessToken: 'token'),
  );

  Future<void> pumpBar(WidgetTester tester, {required bool idleConfirm}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountManagerProvider.overrideWith(
            () => _AccountNotifier([account('a'), account('b')]),
          ),
          confirmPostAccountAfterIdleProvider.overrideWith(
            () => _IdleConfirm(idleConfirm),
          ),
          mountedDeckCountProvider.overrideWith((ref) => 1),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SimplePostBar(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), 'キュアスタ！');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('⚠ 投稿先を尋ねて投稿を選んだら、「投稿しますか？」を重ねない', (tester) async {
    await pumpBar(tester, idleConfirm: true);
    await submit(tester);

    expect(find.text('投稿先の確認'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '投稿'));
    await tester.pumpAndSettle();

    expect(find.text('投稿しますか？'), findsNothing);
    verify(() => adapter.postStatus(any())).called(1);
  });

  testWidgets('前提: 投稿先を尋ねなかったときは「投稿しますか？」を出す', (tester) async {
    // このテストが落ちたら、上のテストは何も検査していない。
    await pumpBar(tester, idleConfirm: false);
    await submit(tester);

    expect(find.text('投稿先の確認'), findsNothing);
    expect(find.text('投稿しますか？'), findsOneWidget);
  });

  testWidgets('⚠ 尋ねずに送れたときも、尋ねる印を下ろす', (tester) async {
    await pumpBar(tester, idleConfirm: false);
    expect(postAccountIdleTracker.pending, isTrue, reason: '前提: 起動直後');
    await submit(tester);
    await tester.tap(find.widgetWithText(TextButton, '投稿'));
    await tester.pumpAndSettle();

    verify(() => adapter.postStatus(any())).called(1);
    expect(postAccountIdleTracker.pending, isFalse);
  });
}

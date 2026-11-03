import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/deck_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/service/post_account_idle_tracker.dart';
import 'package:capsicum/src/ui/util/post_account_confirm.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/gestures.dart';
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

class _IdleConfirmOn extends ConfirmPostAccountAfterIdleNotifier {
  @override
  bool build() => true;
}

/// #1306: デッキで間が空いてから投稿するとき、投稿先を確かめる。
void main() {
  group('PostAccountIdleTracker', () {
    late DateTime now;
    late PostAccountIdleTracker tracker;

    setUp(() {
      now = DateTime(2026, 11, 2, 12);
      tracker = PostAccountIdleTracker(now: () => now);
    });

    void pass(Duration d) => now = now.add(d);

    test('起動直後は再開として扱う', () {
      expect(tracker.pending, isTrue);
    });

    test('確かめたあとは、続けて操作している間は立たない', () {
      tracker.noteActivity();
      tracker.clear();

      pass(const Duration(minutes: 29));
      tracker.noteActivity();
      pass(const Duration(minutes: 29));
      tracker.noteActivity();

      expect(tracker.pending, isFalse);
    });

    test('⚠⚠ 30 分途切れたあとの最初の操作で立つ', () {
      tracker.noteActivity();
      tracker.clear();

      pass(const Duration(minutes: 30));
      expect(tracker.pending, isFalse, reason: '操作が来るまでは分からない');
      tracker.noteActivity();

      expect(tracker.pending, isTrue);
    });

    test('⚠ 立ったあとは、操作が続いても投稿先を確かめるまで下りない', () {
      tracker.noteActivity();
      tracker.clear();
      pass(const Duration(hours: 1));
      tracker.noteActivity();

      pass(const Duration(minutes: 1));
      tracker.noteActivity();

      expect(tracker.pending, isTrue);
    });

    test('⚠ ホイールとトラックパッドのスクロールも操作に数える', () {
      expect(
        PostAccountIdleTracker.isActivity(const PointerDownEvent()),
        isTrue,
      );
      expect(
        PostAccountIdleTracker.isActivity(
          const PointerScrollEvent(scrollDelta: Offset(0, 10)),
        ),
        isTrue,
      );
      expect(
        PostAccountIdleTracker.isActivity(const PointerPanZoomStartEvent()),
        isTrue,
      );
      // 前提: 何でも数えているわけではない。
      expect(
        PostAccountIdleTracker.isActivity(const PointerUpEvent()),
        isFalse,
      );
    });
  });

  group('shouldConfirmPostAccount', () {
    bool decide({
      bool enabled = true,
      bool deckOpen = true,
      int accountCount = 2,
      bool resumed = true,
    }) => shouldConfirmPostAccount(
      enabled: enabled,
      deckOpen: deckOpen,
      accountCount: accountCount,
      resumed: resumed,
    );

    test('条件が揃えば確かめる', () => expect(decide(), isTrue));

    test('⚠ 既定の無効なら確かめない', () {
      expect(decide(enabled: false), isFalse);
    });

    test('タブ表示では確かめない', () {
      expect(decide(deckOpen: false), isFalse);
    });

    test('アカウントが 1 つなら確かめない', () {
      expect(decide(accountCount: 1), isFalse);
    });

    test('再開でなければ確かめない', () {
      expect(decide(resumed: false), isFalse);
    });
  });

  group('confirmPostAccountIfNeeded', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Account account(String name) => Account(
      key: AccountKey(
        type: BackendType.mastodon,
        host: '$name.example',
        username: name,
      ),
      adapter: _Adapter(),
      user: User(id: name, username: name),
      userSecret: const UserSecret(accessToken: 'token'),
    );

    /// ボタンを押すと尋ね、結果を返す。
    Future<Future<PostAccountConfirmResult> Function()> pump(
      WidgetTester tester,
      PostAccountIdleTracker tracker,
    ) async {
      late Future<PostAccountConfirmResult> Function() ask;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountManagerProvider.overrideWith(
              () => _AccountNotifier([account('a'), account('b')]),
            ),
            confirmPostAccountAfterIdleProvider.overrideWith(
              _IdleConfirmOn.new,
            ),
            mountedDeckCountProvider.overrideWith((ref) => 1),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                ask = () =>
                    confirmPostAccountIfNeeded(context, ref, tracker: tracker);
                return const Scaffold();
              },
            ),
          ),
        ),
      );
      return ask;
    }

    testWidgets('再開でなければ尋ねない', (tester) async {
      final tracker = PostAccountIdleTracker()..clear();
      final ask = await pump(tester, tracker);

      expect(await ask(), PostAccountConfirmResult.notAsked);
    });

    testWidgets('⚠ 投稿を選ぶと「尋ねた」を返し、印を下ろす', (tester) async {
      final tracker = PostAccountIdleTracker();
      final ask = await pump(tester, tracker);

      final result = ask();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '投稿'));
      await tester.pumpAndSettle();

      expect(
        await result,
        PostAccountConfirmResult.confirmed,
        reason: '「投稿前に確認する」を重ねない判定に使う',
      );
      expect(tracker.pending, isFalse);
    });

    testWidgets('取り消すと送らず、印は立ったまま', (tester) async {
      final tracker = PostAccountIdleTracker();
      final ask = await pump(tester, tracker);

      final result = ask();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'キャンセル'));
      await tester.pumpAndSettle();

      expect(await result, PostAccountConfirmResult.cancelled);
      expect(tracker.pending, isTrue);
    });

    testWidgets('⚠ サーバーの名前を引く前でも、ホスト名を 2 回出さない', (tester) async {
      final ask = await pump(tester, PostAccountIdleTracker());

      ask();
      await tester.pumpAndSettle();

      expect(find.text('@a@a.example に投稿します。'), findsOneWidget);
    });
  });
}

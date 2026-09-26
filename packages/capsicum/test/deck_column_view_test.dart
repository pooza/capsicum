import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/deck_column.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/server_config_provider.dart';
import 'package:capsicum/src/ui/widget/deck_column_view.dart';
import 'package:capsicum/src/ui/widget/user_avatar.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1148: 読み戻したスレッド / プロフィールのカラム（開いた時点の中身が無い）は、
/// カラムのアカウントで id から取り直す。
class _Adapter extends Mock
    implements DecentralizedBackendAdapter, GallerySupport {}

class _Capabilities extends Mock implements AdapterCapabilities {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Adapter adapter;
  late Account account;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    adapter = _Adapter();
    final capabilities = _Capabilities();
    when(
      () => capabilities.supportedTimelines,
    ).thenReturn({TimelineType.home, TimelineType.local, TimelineType.social});
    when(() => adapter.capabilities).thenReturn(capabilities);
    account = Account(
      key: const AccountKey(
        type: BackendType.misskey,
        host: 'misskey.example',
        username: 'me',
      ),
      adapter: adapter,
      user: const User(id: 'me', username: 'me'),
      userSecret: const UserSecret(accessToken: 'token'),
    );
  });

  Future<void> pump(WidgetTester tester, TabType tab) => tester.pumpWidget(
    ProviderScope(
      overrides: [currentAccountProvider.overrideWithValue(account)],
      child: MaterialApp(
        home: Scaffold(
          body: DeckColumnView(
            column: DeckColumn(id: 'x', account: account.key, tab: tab),
          ),
        ),
      ),
    ),
  );

  testWidgets('seed の無いスレッドは id で取り直し、失敗したら再試行できる', (tester) async {
    var calls = 0;
    when(() => adapter.getPostById('p1')).thenAnswer((_) async {
      calls++;
      throw Exception('boom');
    });

    await pump(tester, const PostThreadTab('p1'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('読み込みに失敗しました'), findsOneWidget);
    expect(find.text('スレッド'), findsOneWidget, reason: 'ヘッダーの見出し');

    await tester.tap(find.text('再試行'));
    await tester.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('seed の無いプロフィールは id で取り直す', (tester) async {
    var calls = 0;
    when(() => adapter.getUserById('u1')).thenAnswer((_) async {
      calls++;
      throw Exception('boom');
    });

    await pump(tester, const ProfileTab('u1'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('読み込みに失敗しました'), findsOneWidget);
  });

  testWidgets('seed の無いギャラリー・メッセージも id で取り直す (#1150)', (tester) async {
    when(
      () => adapter.getGalleryPostById('g1'),
    ).thenAnswer((_) async => throw Exception('boom'));
    await pump(tester, const GalleryPostTab('g1'));
    await tester.pumpAndSettle();
    verify(() => adapter.getGalleryPostById('g1')).called(1);
    expect(find.text('読み込みに失敗しました'), findsOneWidget);
    expect(find.text('ギャラリー'), findsOneWidget, reason: 'ヘッダーの見出し');

    when(
      () => adapter.getUserById('u1'),
    ).thenAnswer((_) async => throw Exception('boom'));
    await pump(tester, const ChatUserTab('u1'));
    await tester.pumpAndSettle();
    verify(() => adapter.getUserById('u1')).called(1);
    expect(find.text('メッセージ'), findsOneWidget);
  });

  testWidgets('⚠ カラムのアカウントで取れない一覧は、取りに行かず案内を出す (#1150)', (tester) async {
    // 投稿タイルの導線はアダプタが対応しているときしか出ないが、読み戻したカラムは
    // アカウントの状態が変わっていることがある。
    await pump(tester, const UserListTab(UserListKind.followers, 'u1'));
    await tester.pumpAndSettle();
    expect(find.text('このアカウントでは表示できません'), findsOneWidget);
    expect(find.text('フォロワー'), findsOneWidget, reason: 'ヘッダーの見出し');
  });

  group('見出し (#1152)', () {
    testWidgets('アカウントのアイコンと表示名を 1 行に出し、@user@host はツールチップで見せる', (
      tester,
    ) async {
      account = account.copyWithUser(
        const User(id: 'me', username: 'me', displayName: 'わたし'),
      );
      await pump(tester, const UserListTab(UserListKind.followers, 'u1'));
      await tester.pumpAndSettle();

      expect(find.text('フォロワー'), findsOneWidget);
      expect(find.text('わたし'), findsOneWidget);
      expect(find.byType(UserAvatar), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == '@me@misskey.example',
        ),
        findsOneWidget,
      );
      // ⚠ 2 行目としては出さない（行を足して本文の面積を削らない）。
      expect(find.text('@me@misskey.example'), findsNothing);
    });

    testWidgets('背景はカラムのアカウントのサーバーの色で、文字は白', (tester) async {
      await pump(tester, const UserListTab(UserListKind.followers, 'u1'));
      await tester.pumpAndSettle();

      final expected = resolveHostColor(const {}, 'misskey.example');
      expect(
        find.byWidgetPredicate((w) => w is ColoredBox && w.color == expected),
        findsOneWidget,
        reason: 'サーバーバッジと同じ色（テーマの面の色ではない）',
      );
      final title = tester.widget<Text>(find.text('フォロワー'));
      expect(title.style?.color, Colors.white);
    });

    testWidgets('⚠ カラムのアカウントと割り当てが食い違うときは、他人のアイコンを出さない', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [currentAccountProvider.overrideWithValue(account)],
          child: const MaterialApp(
            home: Scaffold(
              body: DeckColumnView(
                column: DeckColumn(
                  id: 'y',
                  account: AccountKey(
                    type: BackendType.misskey,
                    host: 'other.example',
                    username: 'someone',
                  ),
                  tab: UserListTab(UserListKind.followers, 'u1'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(UserAvatar), findsNothing);
      expect(find.text('@someone@other.example'), findsOneWidget);
    });
  });

  group('接続ドット (#793)', () {
    const labels = {'ライブ更新中', '接続中…', '切断 — 再接続中', '接続が不安定 — 再試行中', 'ライブ更新オフ'};
    final dot = find.byWidgetPredicate(
      (w) => w is Tooltip && labels.contains(w.message),
    );

    testWidgets('本線のカラムには出す', (tester) async {
      await pump(tester, const TimelineTab(TimelineType.home));
      await tester.pump();
      expect(dot, findsOneWidget, reason: '出ないなら下の DM の検査も空振りしている');
    });

    testWidgets('⚠ DM のカラムには出さない（タブ UI と同じ判定）', (tester) async {
      await pump(tester, const TimelineTab(TimelineType.directMessages));
      await tester.pump();
      expect(dot, findsNothing);
    });
  });
}

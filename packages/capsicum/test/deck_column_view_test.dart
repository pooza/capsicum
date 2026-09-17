import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/deck_column.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/widget/deck_column_view.dart';
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
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

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
}

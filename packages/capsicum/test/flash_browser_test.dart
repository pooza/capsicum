import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/flash_browser_screen.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1351: Play を探す・自分の Play を削除する。
class _Adapter extends Mock
    implements DecentralizedBackendAdapter, FlashSupport {}

class _QueryFake extends Fake implements TimelineQuery {}

class _AccountNotifier extends AccountManagerNotifier {
  _AccountNotifier(this._account);

  final Account _account;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: [_account], current: _account);
}

Flash _flash(String id, String title) => Flash(
  id: id,
  title: title,
  script: '',
  author: const User(id: 'me', username: 'me'),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  late _Adapter adapter;

  setUpAll(() => registerFallbackValue(_QueryFake()));

  setUp(() {
    adapter = _Adapter();
    when(
      () => adapter.getFeaturedFlashes(query: any(named: 'query')),
    ).thenAnswer((_) async => [_flash('f1', '人気の Play')]);
    when(
      () => adapter.getMyFlashes(query: any(named: 'query')),
    ).thenAnswer((_) async => [_flash('m1', '自作の Play')]);
    when(() => adapter.deleteFlash(any())).thenAnswer((_) async {});
  });

  Future<void> pump(WidgetTester tester) async {
    final account = Account(
      key: const AccountKey(
        type: BackendType.misskey,
        host: 'misskey.example',
        username: 'me',
      ),
      adapter: adapter,
      user: const User(id: 'me', username: 'me'),
      userSecret: const UserSecret(accessToken: 'token'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountManagerProvider.overrideWith(() => _AccountNotifier(account)),
        ],
        child: const MaterialApp(home: FlashBrowserScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openMine(WidgetTester tester) async {
    await tester.tap(find.text('自分の'));
    await tester.pumpAndSettle();
  }

  testWidgets('人気のタブには削除が無い', (tester) async {
    await pump(tester);

    expect(find.text('人気の Play'), findsOneWidget);
    expect(find.byTooltip('削除'), findsNothing);
  });

  testWidgets('⚠ 確認で削除を選ぶまで消さない', (tester) async {
    await pump(tester);
    await openMine(tester);

    await tester.tap(find.byTooltip('削除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('「自作の Play」を削除しますか'), findsOneWidget);
    verifyNever(() => adapter.deleteFlash(any()));

    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    verifyNever(() => adapter.deleteFlash(any()));

    await tester.tap(find.byTooltip('削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '削除'));
    await tester.pumpAndSettle();

    verify(() => adapter.deleteFlash('m1')).called(1);
    expect(find.text('Play を削除しました'), findsOneWidget);
  });

  testWidgets('⚠ 古いトークンの 403 は再ログインを案内する', (tester) async {
    final options = RequestOptions(path: '/api/flash/delete');
    when(() => adapter.deleteFlash(any())).thenThrow(
      DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: options,
          statusCode: 403,
          data: {
            'error': {'code': 'PERMISSION_DENIED'},
          },
        ),
      ),
    );
    await pump(tester);
    await openMine(tester);

    await tester.tap(find.byTooltip('削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '削除'));
    await tester.pumpAndSettle();

    expect(find.text('権限が不足しています。再ログインしてください'), findsOneWidget);
  });

  testWidgets('検索は語を渡し、結果に削除を出さない', (tester) async {
    when(
      () => adapter.searchFlashes('おみ', query: any(named: 'query')),
    ).thenAnswer((_) async => [_flash('s1', 'おみくじ')]);
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'おみ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('おみくじ'), findsOneWidget);
    expect(find.byTooltip('削除'), findsNothing);
  });
}

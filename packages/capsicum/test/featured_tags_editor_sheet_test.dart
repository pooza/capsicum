import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/server_config_provider.dart';
import 'package:capsicum/src/ui/widget/featured_tags_editor_sheet.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1075: 自分のプロフィールで紹介するハッシュタグを編集する（書く側）。
class _Adapter extends Mock
    implements DecentralizedBackendAdapter, FeaturedTagSupport {}

void main() {
  late _Adapter adapter;
  late List<List<FeaturedTag>> changes;

  setUp(() {
    adapter = _Adapter();
    changes = [];
    when(
      () => adapter.getFeaturedTagSuggestions(),
    ).thenAnswer((_) async => ['precure_fun', 'PreCure']);
  });

  Future<void> pump(WidgetTester tester, List<FeaturedTag> initial) async {
    final account = Account(
      key: const AccountKey(
        type: BackendType.mastodon,
        host: 'mstdn.example',
        username: 'me',
      ),
      adapter: adapter,
      user: const User(id: 'me', username: 'me'),
      userSecret: const UserSecret(accessToken: 'token'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentAccountProvider.overrideWithValue(account),
          reblogLabelProvider.overrideWithValue('ブースト'),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: FeaturedTagsEditorSheet(
              initial: initial,
              onChanged: changes.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('normalizeFeaturedTagInput', () {
    test('先頭の # と前後の空白を落とす', () {
      expect(normalizeFeaturedTagInput('  #PreCure '), 'PreCure');
      expect(normalizeFeaturedTagInput('##tag'), 'tag');
      expect(normalizeFeaturedTagInput('デルムリン'), 'デルムリン');
    });

    test('空・空白を含むものはタグにならない', () {
      expect(normalizeFeaturedTagInput(''), isNull);
      expect(normalizeFeaturedTagInput('#'), isNull);
      expect(normalizeFeaturedTagInput('two words'), isNull);
    });
  });

  testWidgets('件数と、掲載済みを除いた候補を出す', (tester) async {
    await pump(tester, const [FeaturedTag(id: '1', name: 'precure')]);
    expect(find.text('1 / $featuredTagLimit 件'), findsOneWidget);
    expect(find.text('#precure'), findsOneWidget);
    // 'PreCure' は大文字小文字違いで掲載済み扱い。
    expect(find.text('#precure_fun'), findsOneWidget);
    expect(find.text('#PreCure'), findsNothing);
  });

  testWidgets('入力から追加すると一覧と呼び出し側へ反映する', (tester) async {
    when(
      () => adapter.featureTag('NewTag'),
    ).thenAnswer((_) async => const FeaturedTag(id: '9', name: 'NewTag'));
    await pump(tester, const []);
    expect(find.text('まだ紹介しているハッシュタグはありません'), findsOneWidget);

    await tester.enterText(find.byType(TextField), ' #NewTag ');
    await tester.tap(find.text('追加'));
    await tester.pumpAndSettle();

    verify(() => adapter.featureTag('NewTag')).called(1);
    expect(find.text('#NewTag'), findsOneWidget);
    expect(changes.last.map((t) => t.id), ['9']);
  });

  testWidgets('候補をタップして追加でき、追加した候補は消える', (tester) async {
    when(
      () => adapter.featureTag('precure_fun'),
    ).thenAnswer((_) async => const FeaturedTag(id: '5', name: 'precure_fun'));
    await pump(tester, const []);
    await tester.tap(find.widgetWithText(ActionChip, '#precure_fun'));
    await tester.pumpAndSettle();
    verify(() => adapter.featureTag('precure_fun')).called(1);
    expect(find.widgetWithText(ActionChip, '#precure_fun'), findsNothing);
    expect(find.widgetWithText(InputChip, '#precure_fun'), findsOneWidget);
  });

  testWidgets('外すと ID で消し、呼び出し側へ反映する', (tester) async {
    when(() => adapter.unfeatureTag('1')).thenAnswer((_) async {});
    await pump(tester, const [
      FeaturedTag(id: '1', name: 'precure'),
      FeaturedTag(id: '2', name: 'delmulin'),
    ]);
    await tester.tap(find.byTooltip('#precure を外す'));
    await tester.pumpAndSettle();
    verify(() => adapter.unfeatureTag('1')).called(1);
    expect(find.text('#precure'), findsNothing);
    expect(changes.last.map((t) => t.id), ['2']);
  });

  testWidgets('⚠ 掲載済みのタグ（大文字小文字違い）は送らずに断る', (tester) async {
    await pump(tester, const [FeaturedTag(id: '1', name: 'PreCure')]);
    await tester.enterText(find.byType(TextField), 'precure');
    await tester.tap(find.text('追加'));
    await tester.pumpAndSettle();
    verifyNever(() => adapter.featureTag(any()));
    expect(find.text('#precure はすでに紹介しています'), findsOneWidget);
  });

  testWidgets('上限に達したら入力欄を出さず、理由を出す', (tester) async {
    await pump(tester, [
      for (var i = 0; i < featuredTagLimit; i++)
        FeaturedTag(id: '$i', name: 'tag$i'),
    ]);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('$featuredTagLimit 件までです'), findsOneWidget);
    expect(find.text('最近使ったハッシュタグ'), findsNothing);
  });

  testWidgets('サーバーが断ったら理由を添えて出す', (tester) async {
    final options = RequestOptions(path: '/api/v1/featured_tags');
    when(() => adapter.featureTag('bad')).thenThrow(
      DioException(
        requestOptions: options,
        response: Response(
          requestOptions: options,
          statusCode: 422,
          data: {'error': 'バリデーションに失敗しました: 名前は不正な値です'},
        ),
      ),
    );
    await pump(tester, const []);
    await tester.enterText(find.byType(TextField), 'bad');
    await tester.tap(find.text('追加'));
    await tester.pumpAndSettle();
    expect(find.textContaining('#bad を追加できませんでした'), findsOneWidget);
    expect(changes, isEmpty);
  });
}

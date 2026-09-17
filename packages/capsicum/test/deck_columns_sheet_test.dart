import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/ui/widget/deck_columns_sheet.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1093: カラムの追加・削除（並べ替えの永続化は `deck_columns_test`）。
class _Adapter extends Mock implements DecentralizedBackendAdapter {
  @override
  AdapterCapabilities get capabilities => _Capabilities();
}

class _Capabilities extends Mock implements AdapterCapabilities {
  @override
  Set<TimelineType> get supportedTimelines => {
    TimelineType.home,
    TimelineType.local,
    TimelineType.federated,
  };
}

const _me = AccountKey(
  type: BackendType.mastodon,
  host: 'mstdn.example',
  username: 'me',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> pumpSheet(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        currentAccountProvider.overrideWith(
          (ref) => Account(
            key: _me,
            adapter: _Adapter(),
            user: const User(id: 'me', username: 'me'),
            userSecret: const UserSecret(accessToken: 'token'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: DeckColumnsSheet())),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Finder candidate(String identityKey) =>
      find.byKey(ValueKey('candidate-$identityKey'));

  testWidgets('候補をタップするとカラムが足され、同じものを重ねて足せる', (tester) async {
    final container = await pumpSheet(tester);

    await tester.tap(candidate('timeline:home'));
    await tester.pumpAndSettle();
    await tester.tap(candidate('timeline:home'));
    await tester.pumpAndSettle();

    final columns = container.read(deckColumnsProvider);
    expect(columns, hasLength(2));
    expect(columns.every((c) => c.account == _me), isTrue);
    expect(columns[0].id, isNot(columns[1].id));
  });

  testWidgets('ハッシュタグを入力してカラムを足せる', (tester) async {
    final container = await pumpSheet(tester);

    await tester.enterText(find.byType(TextField), '#delmulin');
    await tester.tap(find.byTooltip('ハッシュタグのカラムを追加'));
    await tester.pumpAndSettle();

    expect(
      container.read(deckColumnsProvider).single.tab,
      const HashtagTab('delmulin'),
    );
  });

  testWidgets('⚠ 重複カラムの片方を削除すると、その 1 本だけが消える（id で指す）', (tester) async {
    final container = await pumpSheet(tester);
    await tester.tap(candidate('timeline:home'));
    await tester.pumpAndSettle();
    await tester.tap(candidate('timeline:home'));
    await tester.pumpAndSettle();
    final [first, second] = container.read(deckColumnsProvider);

    // 2 本目の削除ボタン。
    await tester.tap(find.byTooltip('カラムを削除').at(1));
    await tester.pumpAndSettle();

    expect(container.read(deckColumnsProvider).map((c) => c.id), [first.id]);
    expect(second.id, isNot(first.id));
  });

  testWidgets('カラム 0 本の状態が壊れない', (tester) async {
    final container = await pumpSheet(tester);
    await tester.tap(candidate('timeline:local'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('カラムを削除'));
    await tester.pumpAndSettle();

    expect(container.read(deckColumnsProvider), isEmpty);
    expect(find.text('カラムがありません'), findsOneWidget);
  });
}

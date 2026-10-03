import 'package:capsicum/src/ui/screen/search_screen.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1173: 検索をデッキのカラムとして出す（`docs/deck-ui-plan.md` 決定済み事項 7-3）。
///
/// ⚠ カラムの見出しは `DeckColumnView` が出すので、`Scaffold` / `AppBar` を持たない。
/// **入力欄は chrome ではなく検索の本体**なので、カラムでも残す。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(WidgetTester tester, {required bool embedded}) async {
    SharedPreferences.setMockInitialValues(const {});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: embedded
              // カラムの中と同じ形（高さの制約がある箱の中）に置く。
              ? const Scaffold(body: SearchScreen(embedded: true))
              : const SearchScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('全画面は AppBar を持つ', (tester) async {
    await pump(tester, embedded: false);

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('⚠ カラムは AppBar を持たないが、入力欄は残る', (tester) async {
    await pump(tester, embedded: true);

    expect(
      find.byType(AppBar),
      findsNothing,
      reason: '⚠ 見出しはカラムのヘッダーが出す。二重になる',
    );
    expect(
      find.byType(TextField),
      findsOneWidget,
      reason: '⚠ 入力欄は chrome ではなく検索の本体',
    );
    expect(find.byIcon(Icons.search), findsWidgets);
  });

  testWidgets('⚠⚠ カラムでは autofocus しない（起き直しのたびにキーボードが出る）', (tester) async {
    await pump(tester, embedded: true);

    expect(tester.widget<TextField>(find.byType(TextField)).autofocus, isFalse);
  });

  testWidgets('前提: 全画面では autofocus する（従来の動作を変えない）', (tester) async {
    await pump(tester, embedded: false);

    expect(tester.widget<TextField>(find.byType(TextField)).autofocus, isTrue);
  });
}

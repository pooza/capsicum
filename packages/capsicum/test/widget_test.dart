import 'package:capsicum/main.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// アプリの起動 smoke test。
///
/// 本番の `main()` は runApp() の前に `initSharedPreferencesCache()` で
/// SharedPreferences を pre-warm する（#579 の race を構造的に消すため、
/// provider の `build()` が同期でキャッシュを引く設計）。テストはその
/// main() を通らないので、同じ pre-warm を `debugSetSharedPreferencesCache`
/// で肩代わりしないと `sharedPrefsOrThrow` が StateError を投げる。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    debugSetSharedPreferencesCache(await SharedPreferences.getInstance());
  });

  tearDown(() {
    // グローバルなキャッシュなのでテスト間に持ち越さない。
    debugSetSharedPreferencesCache(null);
  });

  testWidgets('CapsicumApp が例外なく起動する', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: CapsicumApp()));

    expect(find.byType(CapsicumApp), findsOneWidget);
    // pumpWidget 中に build 例外が出ていないこと。ここを見ないと
    // 「widget を pump して同じ widget を探す」だけの素通りテストになる。
    expect(tester.takeException(), isNull);
  });
}

import 'package:capsicum/main.dart';
import 'package:capsicum/src/platform/platform_info.dart';
import 'package:capsicum/src/service/secret_service_probe.dart';
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
///
/// ⚠⚠ **Secret Service の判定はどの OS でも「使わない」に揃える（v1.64）。**
/// 初回起動の索引の読み取りを疎通確認に通したので、Linux の CI では本物の
/// D-Bus に Ping し、その 800ms のタイマー（と読み取りの 5 秒の上限）が
/// widget tree の破棄後も残って落ちた。手元の macOS は疎通確認を通らないので
/// 緑だった（「手元は緑・CI は赤」を 2 回目に踏んだ）。
///
/// ⚠ **OS で結果が変わる形を残さない。**ここは「pump して build が例外を
/// 出さない」ことを見る smoke test で、secure storage の経路は
/// `secure_storage_timeout_test` / `secret_service_probe_test` が Linux の
/// ふりをして固定している。ここで Linux の経路を通すと、storage が応答した
/// 先で main() の初期化（Firebase 等）に当たり、この test の目的から外れる。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    debugSetSharedPreferencesCache(await SharedPreferences.getInstance());
    SecretServiceProbe.resetForTest();
    debugSecretServiceOverride = false;
  });

  tearDown(() {
    // グローバルなキャッシュなのでテスト間に持ち越さない。
    debugSetSharedPreferencesCache(null);
    SecretServiceProbe.resetForTest();
    debugSecretServiceOverride = null;
  });

  testWidgets('CapsicumApp が例外なく起動する', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: CapsicumApp()));

    expect(find.byType(CapsicumApp), findsOneWidget);
    // pumpWidget 中に build 例外が出ていないこと。ここを見ないと
    // 「widget を pump して同じ widget を探す」だけの素通りテストになる。
    expect(tester.takeException(), isNull);
  });
}

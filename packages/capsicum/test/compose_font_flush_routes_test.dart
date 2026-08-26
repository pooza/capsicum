import 'package:capsicum/src/platform/platform_info.dart';
import 'package:capsicum/src/ui/screen/settings/desktop_settings_screen.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1026: フォントファミリ設定の flush が、**実際に発火するか**を見る。
///
/// ⚠⚠ **これは `compose_font_flush_test.dart` の「設定画面の配線」group の
/// 置き換え。**あちらはソース文字列を pin していただけで、
/// 「`dispose` という文字列がファイルにある」ことしか見ていなかった。呼び出しが
/// 届くか・保留中の値が本当に書かれるかは検査していない。#1026 の指摘そのもの。
///
/// あちらが widget test を諦めた理由は「`_ComposeFontSetting` が private」
/// だったが、**それを載せている [DesktopSettingsScreen] は public** なので、
/// 画面ごと pump すれば実物に到達できる。
///
/// 塞ぐ窓は 3 つ。**片方だけでも「flush を呼んでいる」ようには見える**が、
/// 通る経路が違う。
///
/// | 経路 | 塞ぐ窓 |
/// | --- | --- |
/// | `dispose` | 画面を閉じる / 別画面へ移る |
/// | `didChangeAppLifecycleState` | モバイルの終了 |
/// | `onWindowClose` | **デスクトップの ×**（#1026 で追加） |
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const key = 'compose_font_family';
  const typed = 'HackGen Console';

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // ⚠ `setMockInitialValues` だけでは足りない。既に配られた [SharedPreferences]
    // は自前の in-memory cache を持っており、**前のテストが書いた値がそのまま
    // 残る**。各テストの冒頭で「まだ書かれていない」ことを前提にしているので、
    // ここが効いていないと検査が素通りする。
    await prefs.clear();
    initSharedPreferencesCache(prefs);
  });

  /// 設定画面を出し、フォント名を打つところまで。
  ///
  /// ⚠ **flush を待たずに戻る。**デバウンス (400ms) の窓の中に居ることが前提の
  /// 検査なので、ここで `pumpAndSettle` すると窓が閉じてしまう。
  Future<void> openAndType(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: DesktopSettingsScreen())),
    );
    await tester.pump();

    final field = find.byType(TextField);
    expect(
      field,
      findsOneWidget,
      reason: 'フォント入力欄が出ていない。isDesktop のゲートか画面構成が変わった',
    );
    await tester.enterText(field, typed);
    await tester.pump();

    expect(
      prefs.getString(key),
      isNull,
      reason: 'ここで書けていたらデバウンスが効いていない＝この検査は何も見ていない',
    );
  }

  /// native から来るウィンドウイベントを模す。`window_manager` は
  /// `onEvent` の 1 メソッドに全イベントを載せてくる。
  Future<void> emitWindowEvent(WidgetTester tester, String eventName) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'window_manager',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onEvent', {'eventName': eventName}),
      ),
      (_) {},
    );
    await tester.pump();
  }

  // この画面はデスクトップ専用。モバイルでは入力欄自体が出ないので、
  // ホスト側が desktop でないと検査が成り立たない（flutter test は
  // macOS / Linux / Windows のいずれかで走るので通常は満たされる）。
  test('検査の前提: ホストが desktop 扱い', () {
    expect(isDesktop, isTrue);
  });

  testWidgets('デスクトップの × で確定する (#1026)', (tester) async {
    await openAndType(tester);

    await emitWindowEvent(tester, 'close');
    await tester.pumpAndSettle();

    expect(
      prefs.getString(key),
      typed,
      reason:
          'ウィンドウの × は window_manager の native から来るので、'
          'AppLifecycleState.detached が確実に届く保証がない。'
          'onWindowClose に乗せないと 400ms 以内の入力が失われる',
    );
  });

  // 追加した経路が既存の 2 つを壊していないこと。⚠ **3 つとも要る**ので、
  // 「どれか 1 つが効くから十分」と読み替えないこと。
  testWidgets('画面を離れる経路（dispose）でも確定する', (tester) async {
    await openAndType(tester);

    // 画面ごと差し替えて dispose を起こす。
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      ),
    );
    await tester.pumpAndSettle();

    expect(prefs.getString(key), typed);
  });

  testWidgets('モバイルの終了（lifecycle）でも確定する', (tester) async {
    await openAndType(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pumpAndSettle();

    expect(prefs.getString(key), typed);
  });

  // resumed は離脱ではない。ここで書くと、打鍵のたびにフォアグラウンド復帰で
  // 書き込みが走る形になり、デバウンスを入れた意味が薄れる。
  testWidgets('resumed では確定しない', (tester) async {
    await openAndType(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(prefs.getString(key), isNull);

    // 後始末。保留を残したまま抜けるとタイマーが生き残る。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  // ⚠ 画面を離れたあとに native からイベントが来ても、破棄済みの State が
  // 反応してはいけない（`ref` を触って StateError になる）。
  testWidgets('破棄後の × では何も起きない', (tester) async {
    await openAndType(tester);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      ),
    );
    await tester.pumpAndSettle();
    expect(prefs.getString(key), typed, reason: 'dispose 側で確定している');

    // 破棄後に届いても例外にならないこと。
    await emitWindowEvent(tester, 'close');
    await tester.pumpAndSettle();
  });
}

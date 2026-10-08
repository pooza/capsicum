import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/deck_screen.dart';
import 'package:capsicum/src/ui/util/mouse_drag_scroll_behavior.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1157: デッキのカラムをマウス / トラックパッドで引っ張れるようにする。
///
/// ⚠⚠ **デスクトップでは「引っ張って更新」ができなかった。**マウスと
/// トラックパッドは Flutter の既定の `dragDevices` に入っておらず、2 本指
/// スクロールは**ポインタスクロール**として届くため `RefreshIndicator` が
/// 起動しない。カラムには引っ張る以外の再読み込みの入口も無く、実機検証
/// （[#1098](https://github.com/pooza/capsicum/issues/1098) の B10）では
/// 「カラムを閉じて足し直す」で代替するしかなかった。
///
/// ⚠ **設定 (#574) に従う**（2026-09-19 pooza 判断）。既定の OFF では、
/// トラックパッド 2 本指スワイプの既存挙動をそのまま維持する。

class _Adapter extends Mock implements DecentralizedBackendAdapter {}

Account _account() => Account(
  key: const AccountKey(
    type: BackendType.misskey,
    host: 'misskey.example',
    username: 'me',
  ),
  adapter: _Adapter(),
  user: const User(id: 'me', username: 'me'),
  userSecret: const UserSecret(accessToken: 'token'),
);

class _TestAccounts extends AccountManagerNotifier {
  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: [_account()], current: _account());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpDeck(
    WidgetTester tester, {
    required bool mouseDragEnabled,
  }) async {
    SharedPreferences.setMockInitialValues({
      'deck_columns': ['c1|misskey://me@misskey.example|timeline:home'],
      if (mouseDragEnabled) 'mouse_drag_scroll': true,
    });
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [accountManagerProvider.overrideWith(_TestAccounts.new)],
        child: MaterialApp(
          home: DeckScreen(
            columnBuilder: (column) => const SizedBox(key: Key('stub')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final mouseDragScope = find.byWidgetPredicate(
    (w) => w is ScrollConfiguration && w.behavior is MouseDragScrollBehavior,
  );

  testWidgets('⚠⚠ 設定 ON ならマウス / トラックパッドで引っ張れる（更新の入口になる）', (tester) async {
    await pumpDeck(tester, mouseDragEnabled: true);

    expect(mouseDragScope, findsOneWidget);
    final behavior =
        (tester.widget(mouseDragScope) as ScrollConfiguration).behavior;
    expect(
      behavior.dragDevices,
      containsAll([PointerDeviceKind.mouse, PointerDeviceKind.trackpad]),
      reason: '⚠ 既定の dragDevices はタッチ / スタイラスだけで、引っ張れない',
    );
  });

  testWidgets('⚠ 既定 (OFF) では被せない（トラックパッド 2 本指の既存挙動を変えない）', (tester) async {
    await pumpDeck(tester, mouseDragEnabled: false);

    expect(mouseDragScope, findsNothing);
  });
}

import 'dart:async';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/deck_provider.dart';
import 'package:capsicum/src/ui/screen/deck_screen.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1340: デッキの上に画面を push / pop しても、デッキ全体を作り直さない。
///
/// ⚠ 以前は DeckScreen 自身の context で `ModalRoute.of` を呼んでいたので、
/// 上に画面が載るたび（`isCurrent` が変わるたび）に依存で作り直されていた。
/// 作り直しは `columnBuilder` の呼ばれた回数で測る（DeckScreen の build が
/// カラムごとに呼ぶ）。
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

const _me = AccountKey(
  type: BackendType.misskey,
  host: 'misskey.example',
  username: 'me',
);

Account _account(AccountKey key) => Account(
  key: key,
  adapter: _Adapter(),
  user: User(id: key.username, username: key.username),
  userSecret: const UserSecret(accessToken: 'token'),
);

class _TestAccountNotifier extends AccountManagerNotifier {
  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: [_account(_me)], current: _account(_me));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('⚠⚠ 上に画面を積んでも戻しても、デッキを作り直さない', (tester) async {
    SharedPreferences.setMockInitialValues({
      'deck_columns': ['a|misskey://me@misskey.example|hashtag:a'],
    });
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(_TestAccountNotifier.new),
      ],
    );
    addTearDown(container.dispose);

    var builds = 0;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DeckScreen(
            columnBuilder: (column) {
              builds++;
              return SizedBox.expand(key: ValueKey('stub-${column.id}'));
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = builds;
    expect(before, greaterThan(0), reason: '数え方が空振りしていない');

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('上の画面')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('上の画面'), findsOneWidget);
    expect(builds, before, reason: 'push で作り直さない');

    navigator.pop();
    await tester.pumpAndSettle();
    expect(builds, before, reason: 'pop で作り直さない');
    expect(
      container.read(mountedDeckCountProvider),
      1,
      reason: '上の画面の pop で、デッキが開いている数から抜けない',
    );
  });
}

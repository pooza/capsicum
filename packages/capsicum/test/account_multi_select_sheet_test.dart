import 'package:capsicum/src/ui/widget/account_multi_select_sheet.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// #866: コレクション初期メンバー選択の複数選択シート。
///
/// 検索（SearchSupport）はサーバー依存で harness が重いため、ここでは selection の
/// 契約（初期選択の反映・チップ削除でのトグル・「決定」で選択リストを返す）を
/// 検証する。initial 経由なので provider override は不要。
void main() {
  User user(String id, String name) =>
      User(id: id, username: name, displayName: name);

  Future<List<User>?> openAndReturn(
    WidgetTester tester, {
    required List<User> initial,
  }) async {
    List<User>? result;
    late BuildContext ctx;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    // シートを開き、返り値を捕捉する（await は tap 後にまとめて進める）。
    // ignore: use_build_context_synchronously
    showAccountMultiSelectSheet(ctx, initial: initial).then((r) => result = r);
    await tester.pumpAndSettle();
    return Future.value(result);
  }

  testWidgets('初期メンバーは選択済みチップで表示される', (tester) async {
    await openAndReturn(
      tester,
      initial: [user('1', 'alice'), user('2', 'bob')],
    );
    expect(find.widgetWithText(Chip, '@alice'), findsOneWidget);
    expect(find.widgetWithText(Chip, '@bob'), findsOneWidget);
    expect(find.text('決定（2）'), findsOneWidget);
  });

  testWidgets('「決定」で選択中の User リストを返す', (tester) async {
    List<User>? result;
    late BuildContext ctx;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    showAccountMultiSelectSheet(
      ctx,
      initial: [user('1', 'alice'), user('2', 'bob')],
    ).then((r) => result = r);
    await tester.pumpAndSettle();

    await tester.tap(find.text('決定（2）'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.map((u) => u.id).toList(), ['1', '2']);
  });

  testWidgets('チップ削除で選択から外れ、カウントが減る', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    showAccountMultiSelectSheet(
      ctx,
      initial: [user('1', 'alice'), user('2', 'bob')],
    );
    await tester.pumpAndSettle();

    // alice チップの削除アイコンを押す。
    final aliceChip = find.widgetWithText(Chip, '@alice');
    await tester.tap(
      find.descendant(of: aliceChip, matching: find.byIcon(Icons.cancel)),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(Chip, '@alice'), findsNothing);
    expect(find.text('決定（1）'), findsOneWidget);
  });
}

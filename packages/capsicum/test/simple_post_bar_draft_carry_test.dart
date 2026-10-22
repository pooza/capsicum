import 'package:capsicum/src/ui/widget/simple_post_bar.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// デッキの簡易投稿バーは、フォーカスが移るたびに作り直す（key がカラムの id）。
///
/// ⚠⚠ **打ちかけの本文は消さずに、移った先のバーへ引き継ぐ**（2026-10-22 pooza
/// 「カラムが変わった時に、入力中の投稿を空にしたりもしない」）。#1330 で
/// スクロールでもフォーカスが移るようになり、v2.5 のリリース前レビューで
/// 「読みながら書く途中で本文が消える」と分かった。正本は
/// `docs/deck-ui-decisions.md` 決定済み事項 10。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpBar(
    WidgetTester tester,
    String columnId,
    PostBarDraft? draft,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SimplePostBar(key: ValueKey(columnId), draft: draft),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
  });

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  bool fieldHasFocus(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus;

  testWidgets('⚠⚠ カラムが変わって作り直されても、打ちかけの本文とフォーカスを引き継ぐ', (tester) async {
    final draft = PostBarDraft();
    await pumpBar(tester, 'a', draft);
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'キュアスタ！で書きかけ');
    await tester.pump();

    await pumpBar(tester, 'b', draft);
    await tester.pump();

    expect(fieldText(tester), 'キュアスタ！で書きかけ');
    expect(fieldHasFocus(tester), isTrue, reason: '移った先でもそのまま打ち続けられる');
  });

  testWidgets('入力欄にフォーカスが無ければ、引き継いでも奪わない', (tester) async {
    final draft = PostBarDraft();
    await pumpBar(tester, 'a', draft);
    await tester.enterText(find.byType(TextField), '書きかけ');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    await pumpBar(tester, 'b', draft);
    await tester.pump();

    expect(fieldText(tester), '書きかけ');
    expect(fieldHasFocus(tester), isFalse);
  });

  testWidgets('前提: 控えを渡さないバー（タブ UI）は、作り直すと空になる', (tester) async {
    // 引き継ぐのは控えの働きで、作り直しそのものではないことを確かめる
    // （このテストが落ちたら、上の 2 本は何も検査していない）。
    await pumpBar(tester, 'a', null);
    await tester.enterText(find.byType(TextField), '書きかけ');
    await tester.pump();

    await pumpBar(tester, 'b', null);
    await tester.pump();

    expect(fieldText(tester), isEmpty);
  });
}

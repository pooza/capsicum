import 'package:capsicum/src/ui/widget/quick_chooser_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #982: 「読み込んで一覧するクイックチューザ」の外枠。
///
/// 投稿テンプレートとサーバー下書きが同じ足場を丸写ししており、片方だけ体裁を
/// 直すと「同じ操作なのに画面によって見え方が違う」になっていた。寄せた以上、
/// **4 状態（読み込み中 / 失敗 / 空 / 一覧）の出し分け**はここで固定する。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    bool loading = false,
    String? error,
    List<Widget> items = const [],
    Widget? footer,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: QuickChooserSheet(
          title: 'みだし',
          loading: loading,
          error: error,
          emptyMessage: 'からっぽ',
          items: items,
          footer: footer,
        ),
      ),
    ),
  );

  testWidgets('読み込み中はスピナーだけで、空文言も一覧も出さない', (tester) async {
    await pump(tester, loading: true, footer: const Text('かんり'));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('からっぽ'), findsNothing);
    // ⚠ 一覧が確定していない間に管理へ飛ばさない。
    expect(find.text('かんり'), findsNothing);
  });

  testWidgets('失敗時は文言だけを出し、管理導線は出さない', (tester) async {
    await pump(tester, error: 'よみこめませんでした', footer: const Text('かんり'));
    expect(find.text('よみこめませんでした'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('からっぽ'), findsNothing);
    expect(find.text('かんり'), findsNothing);
  });

  testWidgets('空でも管理導線は出す（1 件も無い状態から管理画面へ行けないと詰む）', (tester) async {
    await pump(tester, footer: const Text('かんり'));
    expect(find.text('からっぽ'), findsOneWidget);
    expect(find.text('かんり'), findsOneWidget);
  });

  testWidgets('管理導線が無いシートでは区切り線も出ない', (tester) async {
    await pump(tester, items: const [Text('いち')]);
    expect(find.text('いち'), findsOneWidget);
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('一覧があれば空文言は出さず、見出しは常に出る', (tester) async {
    await pump(
      tester,
      items: const [Text('いち'), Text('に')],
      footer: const Text('かんり'),
    );
    expect(find.text('みだし'), findsOneWidget);
    expect(find.text('いち'), findsOneWidget);
    expect(find.text('に'), findsOneWidget);
    expect(find.text('からっぽ'), findsNothing);
    expect(find.byType(Divider), findsOneWidget);
  });
}

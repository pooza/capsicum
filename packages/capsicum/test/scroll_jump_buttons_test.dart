import 'dart:io';

import 'package:capsicum/src/ui/widget/scroll_jump_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1244: 一覧の先頭・末尾へ飛ぶボタン（△▽）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host({
    required bool showTop,
    VoidCallback? onTop,
    VoidCallback? onBottom,
  }) => ScrollJumpButtons(
    showTop: showTop,
    onTop: onTop ?? () {},
    onBottom: onBottom ?? () {},
  );

  testWidgets('先頭に居るあいだは ▽ だけを出す', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: host(showTop: false))),
    );

    expect(find.byTooltip('先頭へ'), findsNothing, reason: '押しても何も起きないボタンを出さない');
    expect(find.byTooltip('末尾へ'), findsOneWidget);
  });

  testWidgets('先頭から離れると △ も出て、それぞれの行き先を呼ぶ', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: host(
            showTop: true,
            onTop: () => calls.add('top'),
            onBottom: () => calls.add('bottom'),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('先頭へ'));
    await tester.tap(find.byTooltip('末尾へ'));

    expect(calls, ['top', 'bottom']);
  });

  testWidgets('⚠⚠ 同じ画面に何組あっても、画面遷移で Hero が衝突しない', (tester) async {
    // デッキではカラムの数 × 2 個が同じ route に並ぶ。`heroTag` が既定のままだと
    // 「複数の Hero が同じタグを持っている」で遷移のたびに落ちる。
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Row(
              children: [
                host(showTop: true),
                host(showTop: true),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(body: host(showTop: true)),
                    ),
                  ),
                  child: const Text('push'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  /// ボタンが正しくても、置かれていなければ出ない。
  group('タブ UI とデッキのカラムの両方に置いてある', () {
    for (final path in [
      'lib/src/ui/screen/home_screen.dart',
      'lib/src/ui/widget/deck_column_view.dart',
    ]) {
      test(path, () {
        expect(File(path).readAsStringSync(), contains('ScrollJumpButtons('));
      });
    }
  });
}

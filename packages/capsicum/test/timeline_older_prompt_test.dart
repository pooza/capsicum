import 'package:capsicum/src/ui/widget/timeline_older_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1283: 空のまま続きがある TL から、手で先を引く入口。
void main() {
  Future<int Function()> pump(
    WidgetTester tester, {
    required bool isLoading,
  }) async {
    var pressed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimelineOlderPrompt(
            isLoading: isLoading,
            onLoadOlder: () => pressed++,
          ),
        ),
      ),
    );
    return () => pressed;
  }

  testWidgets('押すと続きを引く', (tester) async {
    final pressed = await pump(tester, isLoading: false);

    expect(find.text('絞り込みで多くの投稿が除外されています'), findsOneWidget);
    await tester.tap(find.text('さらに古い投稿を探す'));
    expect(pressed(), 1);
  });

  testWidgets('取得中はボタンを出さない（二重に引かせない）', (tester) async {
    await pump(tester, isLoading: true);

    expect(find.text('さらに古い投稿を探す'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}

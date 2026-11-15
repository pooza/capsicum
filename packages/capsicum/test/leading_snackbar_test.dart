import 'package:capsicum/src/ui/util/fediverse_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「リンクを開いています…」を閉じるとき、別の SnackBar を消さない
/// （#1379・v2.12 のリリース前レビュー）。
void main() {
  late ScaffoldMessengerState messenger;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              messenger = ScaffoldMessenger.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  testWidgets('別の SnackBar が出ていても、自分だけを閉じる', (tester) async {
    await pump(tester);
    messenger.showSnackBar(const SnackBar(content: Text('前の知らせ')));
    await tester.pumpAndSettle();

    final close = showLeadingSnackBar(
      messenger,
      const SnackBar(content: Text('開いています')),
    );
    await tester.pumpAndSettle();
    expect(find.text('開いています'), findsOneWidget);
    expect(find.text('前の知らせ'), findsNothing);

    // 閉じたあとに出したものは消さない。
    close();
    messenger.showSnackBar(const SnackBar(content: Text('開けませんでした')));
    await tester.pumpAndSettle();
    expect(find.text('開いています'), findsNothing);
    expect(find.text('開けませんでした'), findsOneWidget);
  });

  testWidgets('閉じる前に後ろへ並んだものは、閉じたあとに出る', (tester) async {
    await pump(tester);
    final close = showLeadingSnackBar(
      messenger,
      const SnackBar(content: Text('開いています')),
    );
    messenger.showSnackBar(const SnackBar(content: Text('あとの知らせ')));
    await tester.pumpAndSettle();
    expect(find.text('開いています'), findsOneWidget);

    close();
    await tester.pumpAndSettle();
    expect(find.text('開いています'), findsNothing);
    expect(find.text('あとの知らせ'), findsOneWidget);
  });

  testWidgets('時間切れで閉じていたら、閉じる関数は何もしない', (tester) async {
    await pump(tester);
    final close = showLeadingSnackBar(
      messenger,
      const SnackBar(
        content: Text('開いています'),
        duration: Duration(milliseconds: 100),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('開いています'), findsNothing);

    messenger.showSnackBar(const SnackBar(content: Text('別の知らせ')));
    await tester.pumpAndSettle();
    close();
    await tester.pumpAndSettle();
    expect(find.text('別の知らせ'), findsOneWidget);
  });
}

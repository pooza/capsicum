import 'package:capsicum/src/ui/util/relative_time.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // テストは macOS ホストで走るため isDesktop == true。
  // デスクトップで相対表示のときだけ絶対日時ツールチップが付くことを確認する
  // （#754）。
  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  final time = DateTime.utc(2026, 3, 26, 3, 34); // ローカル表示は端末 TZ 依存

  testWidgets('絶対表示のときはツールチップを付けない', (tester) async {
    await tester.pumpWidget(wrap(TimestampText(time, absolute: true)));

    expect(find.byType(Tooltip), findsNothing);
    expect(find.text(formatAbsoluteTime(time)), findsOneWidget);
  });

  testWidgets('相対表示のときデスクトップでは絶対日時ツールチップを付ける', (tester) async {
    await tester.pumpWidget(wrap(TimestampText(time, absolute: false)));

    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, formatAbsoluteTime(time));
    // 本文は相対表示のまま。
    expect(find.text(formatRelativeTime(time)), findsOneWidget);
  });
}

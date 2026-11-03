import 'package:capsicum/src/ui/screen/server_selection_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1007: 未接続アカウントの「接続し直す」で開いたとき、接続先が一覧の下に
/// 埋もれていた（ラベルも「その他のサーバー」のままだった）。
void main() {
  Future<void> pump(WidgetTester tester, {String? initialHost}) async {
    // ⚠ 入力欄は一覧の下なので、狭いと ListView が作らない。
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ServerSelectionScreen(initialHost: initialHost),
        ),
      ),
    );
  }

  testWidgets('接続先を一覧より上に出し、入力欄へは埋めない', (tester) async {
    await pump(tester, initialHost: 'example.com');

    final heading = find.text('example.com に接続し直す');
    final presets = find.text('プリセットサーバーを選択');
    expect(heading, findsOneWidget);
    expect(presets, findsOneWidget);
    expect(
      tester.getTopLeft(heading).dy,
      lessThan(tester.getTopLeft(presets).dy),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('接続先が無ければ、ふだんの画面のまま', (tester) async {
    await pump(tester);

    expect(find.textContaining('に接続し直す'), findsNothing);
  });

  testWidgets('空の接続先は無いものとして扱う', (tester) async {
    await pump(tester, initialHost: '  ');

    expect(find.textContaining('に接続し直す'), findsNothing);
  });
}

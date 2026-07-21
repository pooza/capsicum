import 'package:capsicum/src/ui/widget/page_block_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Misskey Pages の廃止済み動的ブロックの案内 (#616)。
///
/// 「未対応です」（capsicum が追いついていない）と「廃止されています」
/// （本家でも表示されない）は、ユーザーに伝える意味が違う。取り違えると
/// 「capsicum の実装漏れ」と誤解されるため、出し分けを固定する。
Future<void> _pump(WidgetTester tester, List<Map<String, dynamic>> blocks) {
  return tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: PageBlockRenderer(blocks: blocks)),
        ),
      ),
    ),
  );
}

void main() {
  group('PageBlockRenderer 廃止済みブロック (#616)', () {
    testWidgets('廃止済みの動的ブロックは本家準拠の案内を出す', (tester) async {
      await _pump(tester, [
        {'type': 'button'},
      ]);

      expect(find.text('動的ブロック'), findsOneWidget);
      expect(find.text('このブロックは廃止されています。今後は Play を利用してください。'), findsOneWidget);
      // 「未対応」とは言わない。
      expect(find.textContaining('未対応'), findsNothing);
    });

    testWidgets('本家が廃止扱いする type をすべて拾う', (tester) async {
      // 出典: 本家 packages/frontend/src/components/page/page.block.vue
      const deprecated = [
        'button',
        'if',
        'textarea',
        'post',
        'canvas',
        'numberInput',
        'textInput',
        'switch',
        'radioButton',
        'counter',
      ];

      await _pump(tester, [
        for (final type in deprecated) {'type': type},
      ]);

      expect(find.text('動的ブロック'), findsNWidgets(deprecated.length));
      expect(find.textContaining('未対応'), findsNothing);
    });

    testWidgets('未知の type は従来どおり「未対応」と type 名を出す', (tester) async {
      await _pump(tester, [
        {'type': 'somethingNew'},
      ]);

      expect(find.text('このブロックは未対応です (somethingNew)'), findsOneWidget);
      expect(find.text('動的ブロック'), findsNothing);
    });

    testWidgets('type 欠落は未対応として扱う', (tester) async {
      await _pump(tester, [<String, dynamic>{}]);

      expect(find.text('このブロックは未対応です ((unknown))'), findsOneWidget);
    });
  });
}

import 'package:capsicum/src/ui/widget/featured_tags_section.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1075: プロフィールで紹介しているハッシュタグ。
void main() {
  Future<List<FeaturedTag>> pump(
    WidgetTester tester,
    List<FeaturedTag> tags,
  ) async {
    final tapped = <FeaturedTag>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeaturedTagsSection(tags: tags, onTap: tapped.add),
        ),
      ),
    );
    return tapped;
  }

  testWidgets('本人が選んだ順にチップを並べ、件数を添える', (tester) async {
    await pump(tester, [
      FeaturedTag(
        name: 'PreCure',
        statusesCount: 42,
        lastStatusAt: DateTime(2026, 9, 4),
      ),
      const FeaturedTag(name: 'delmulin'),
    ]);
    expect(find.text('紹介しているハッシュタグ'), findsOneWidget);
    expect(find.text('#PreCure  42'), findsOneWidget);
    expect(find.text('#delmulin'), findsOneWidget, reason: '0 件なら数字を出さない');
    final first = tester.getTopLeft(find.text('#PreCure  42'));
    final second = tester.getTopLeft(find.text('#delmulin'));
    expect(first.dx, lessThan(second.dx));
    expect(find.byTooltip('42 件の投稿・最終投稿 2026/09/04'), findsOneWidget);
  });

  testWidgets('タップしたタグを呼び出し側へ渡す', (tester) async {
    final tapped = await pump(tester, [
      const FeaturedTag(name: 'PreCure'),
      const FeaturedTag(name: 'delmulin'),
    ]);
    await tester.tap(find.text('#delmulin'));
    expect(tapped.map((t) => t.name), ['delmulin']);
  });
}

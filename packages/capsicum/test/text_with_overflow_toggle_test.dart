import 'package:capsicum/src/ui/widget/text_with_overflow_toggle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1369: 本文が行数の上限で切れているのに「続きを読む」が出ない件。
///
/// テスト用のフォントは 1 文字が文字サイズちょうどの正方形なので、幅 100・
/// 文字サイズ 10 なら 1 行 10 文字になる。80 文字は倍率 1.0 でちょうど 8 行、
/// 1.1 倍（1 文字 11px → 1 行 9 文字）では 9 行になって切れる。
const _width = 100.0;
// ⚠ 字間を 0 にする。Material の既定（bodyMedium）の 0.3 を引き継ぐと 1 文字が
// 10.3px になり、倍率 1.0 でも 9 行になる。
const _style = TextStyle(fontSize: 10, height: 1, letterSpacing: 0);
final _eightLines = 'あ' * 80;

Widget _harness({
  required InlineSpan span,
  double scale = 1.0,
  bool expanded = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: _width,
          child: TextWithOverflowToggle(
            text: Text.rich(
              span,
              maxLines: expanded ? null : 8,
              overflow: expanded ? null : TextOverflow.ellipsis,
            ),
            toggle: Text(expanded ? '折り畳む' : '続きを読む'),
            // 展開中は、上限を付けた同じ本文で測る（PostTile と同じ渡し方）。
            collapsedText: expanded
                ? Text.rich(span, maxLines: 8, overflow: TextOverflow.ellipsis)
                : null,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('文字サイズを上げて表示が切れたら、「続きを読む」を出す', (tester) async {
    await tester.pumpWidget(
      _harness(
        span: TextSpan(text: _eightLines, style: _style),
        scale: 1.1,
      ),
    );

    expect(_showsToggle(tester), isTrue);
  });

  testWidgets('対照: 素の文字列を倍率なしの TextPainter で測ると、切れていないと見誤る', (tester) async {
    // ⚠ 修正前の測り方。これが true になったら（Flutter の既定が変わって）
    // 上のテストは何も守っていないことになるので、原因から見直す。
    final painter = TextPainter(
      text: TextSpan(text: _eightLines, style: _style),
      maxLines: 8,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: _width);
    addTearDown(painter.dispose);

    expect(painter.didExceedMaxLines, isFalse);
  });

  testWidgets('倍率 1.0 でちょうど 8 行なら、「続きを読む」を出さない', (tester) async {
    await tester.pumpWidget(
      _harness(
        span: TextSpan(text: _eightLines, style: _style),
      ),
    );

    expect(_showsToggle(tester), isFalse);
  });

  testWidgets('カスタム絵文字（WidgetSpan）の幅で切れたときも出す', (tester) async {
    // 75 文字 + 幅 60 の絵文字 1 つ。素の文字列なら 8 行に収まるが、表示では
    // 絵文字が 9 行目へ押し出される。
    await tester.pumpWidget(
      _harness(
        span: TextSpan(
          style: _style,
          children: [
            TextSpan(text: 'あ' * 75),
            const WidgetSpan(child: SizedBox(width: 60, height: 10)),
          ],
        ),
      ),
    );

    expect(_showsToggle(tester), isTrue);
  });

  testWidgets('短い本文には出さない', (tester) async {
    await tester.pumpWidget(
      _harness(
        span: const TextSpan(text: '短い', style: _style),
      ),
    );

    expect(_showsToggle(tester), isFalse);
  });

  testWidgets('展開中は、長い本文なら「折り畳む」を出し、全文を描く', (tester) async {
    await tester.pumpWidget(
      _harness(
        span: TextSpan(text: _eightLines, style: _style),
        scale: 1.1,
        expanded: true,
      ),
    );

    expect(_showsToggle(tester), isTrue);
    await tester.tap(find.text('折り畳む'));
    final render = tester.renderObject<RenderTextWithOverflowToggle>(
      find.byType(TextWithOverflowToggle),
    );
    // 9 行（1 行 11px）+「折り畳む」の行。測る専用の子の高さは足さない。
    expect(render.size.height, greaterThan(9 * 11));
  });

  testWidgets('⚠ 展開中でも、短い本文には「折り畳む」を出さない', (tester) async {
    // スレッドの対象の投稿は最初から展開して出す。「展開中は常に出す」に
    // すると、ここが壊れる。
    await tester.pumpWidget(
      _harness(
        span: const TextSpan(text: '短い', style: _style),
        expanded: true,
      ),
    );

    expect(_showsToggle(tester), isFalse);
  });

  testWidgets('「続きを読む」は押せる', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: _width,
            child: TextWithOverflowToggle(
              text: Text(_eightLines * 2, style: _style, maxLines: 8),
              toggle: GestureDetector(
                onTap: () => tapped++,
                child: const Text('続きを読む'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('続きを読む'));
    expect(tapped, 1);
  });

  testWidgets('「続きを読む」が出るぶん、欄の高さが 1 回のレイアウトで決まる', (tester) async {
    // 次のフレームで出し分けると、欄の高さが遅れて変わりスクロールが跳ねる
    // （#1032 と同じ形）。最初のフレームで出ていることを固定する。
    await tester.pumpWidget(
      _harness(
        span: TextSpan(text: _eightLines, style: _style),
        scale: 1.1,
      ),
    );

    final render = tester.renderObject<RenderTextWithOverflowToggle>(
      find.byType(TextWithOverflowToggle),
    );
    expect(render.showsToggle, isTrue);
    expect(render.size.height, greaterThan(8 * 11));
  });
}

/// 「続きを読む」を置いたか。⚠ 置かないときもウィジェットはツリーに残る
/// （大きさ 0 で描かない）ので、`find.text` では数えられない。
bool _showsToggle(WidgetTester tester) => tester
    .renderObject<RenderTextWithOverflowToggle>(
      find.byType(TextWithOverflowToggle),
    )
    .showsToggle;

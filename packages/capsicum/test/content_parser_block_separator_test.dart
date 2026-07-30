import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #897: 引用 / コードブロック（末尾 \n を持たない #842 対策のブロック要素）の
/// 直後に空行なしで次の行が続くと、その行がブロックの右側にインライン表示されて
/// しまう。ブロックの後に続きがあるときだけ区切りの \n を 1 つ補い、次行へ落とす。
///
/// 同時に守るべき不変条件:
/// - 末尾（後続なし）のブロックには \n を足さない（#842 のブロック高の空白を
///   再発させない）。
/// - ソースに空行があるケース（後続が \n 始まり）で二重改行にしない。
void main() {
  ContentRenderer newRenderer() {
    final r = ContentRenderer(
      baseStyle: const TextStyle(fontSize: 14),
      resolveEmoji: (name) => 'https://example.test/emoji/$name.webp',
    );
    addTearDown(r.dispose);
    return r;
  }

  /// 引用ブロックを表す WidgetSpan の位置を返す（先頭 \n の直後）。無ければ -1。
  int quoteWidgetIndex(List<InlineSpan> spans) =>
      spans.indexWhere((s) => s is WidgetSpan);

  String? textOf(InlineSpan span) => span is TextSpan ? span.text : null;

  test('引用の直後に空行なしで続く行は、区切りの \\n を挟んで次行へ落ちる', () {
    final spans = newRenderer().renderMfm('> 引用の行\n次の行').children!;
    final qi = quoteWidgetIndex(spans);
    expect(qi, greaterThanOrEqualTo(0), reason: '引用は WidgetSpan で描画される');
    expect(
      textOf(spans[qi + 1]),
      '\n',
      reason: '引用ブロックの直後に区切りの \\n が入り、次の行が右側へ流れない (#897)',
    );
  });

  test('末尾の引用ブロックには区切りの \\n を足さない（#842 の空白回避）', () {
    final spans = newRenderer().renderMfm('> 引用の行').children!;
    final qi = quoteWidgetIndex(spans);
    expect(qi, greaterThanOrEqualTo(0));
    // WidgetSpan がリスト末尾、もしくは直後に余計な \n が無いこと。
    final trailing = qi + 1 < spans.length ? textOf(spans[qi + 1]) : null;
    expect(trailing, isNot('\n'), reason: '末尾ブロックに末尾 \\n を付けない (#842)');
  });

  test('空行ありのケースは二重改行にしない（後続が \\n 始まり）', () {
    final spans = newRenderer().renderMfm('> 引用の行\n\n次の行').children!;
    final qi = quoteWidgetIndex(spans);
    expect(qi, greaterThanOrEqualTo(0));
    // 引用直後の span は後続テキスト由来の \n 始まりで、こちらが補う \n と
    // 合わせて 2 連続 '\n' の TextSpan にならないこと。
    final next = spans[qi + 1];
    final nextText = textOf(next);
    if (nextText == '\n') {
      // 補った区切りが独立 span で入っているなら、その次が更に \n 始まりでは
      // ないこと（二重改行の回避）。
      final after = qi + 2 < spans.length ? textOf(spans[qi + 2]) : null;
      expect(
        after?.startsWith('\n'),
        isNot(true),
        reason: '区切りの \\n と空行由来の \\n が重ならない (#897)',
      );
    } else {
      // 後続テキストが自前で \n 始まりなら、補いはスキップされている。
      expect(nextText?.startsWith('\n'), true);
    }
  });

  test('コードブロックの直後に続く行も次行へ落ちる（区切り \\n か後続の \\n 始まりで）', () {
    final spans = newRenderer().renderMfm('```\ncode\n```\n次の行').children!;
    final ci = spans.indexWhere((s) => s is WidgetSpan);
    expect(ci, greaterThanOrEqualTo(0), reason: 'コードブロックは WidgetSpan で描画される');
    // コードフェンスの解析は閉じ ``` の後の \n を後続テキストの先頭に残すため、
    // このソースでは補いの \n はスキップされ、後続テキスト自体が \n 始まりになる。
    // どちらの経路でも「次行へ落ちる」ことが担保できていればよい。
    final next = textOf(spans[ci + 1]);
    expect(
      next == '\n' || (next?.startsWith('\n') ?? false),
      true,
      reason: 'コードブロック直後の行が右側へ流れず次行へ落ちる (#897)',
    );
  });
}

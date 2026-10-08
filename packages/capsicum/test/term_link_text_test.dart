import 'package:capsicum/src/ui/widget/term_link_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// [TermLinkText]（段落の中の 1 語をリンクにする・#1221）。
///
/// ⚠⚠ **見るのは「光るのが 1 箇所だけか」と「文字が落ちないか」。**#1221 の
/// 完了条件が前者で、後者は substring で切り貼りする実装の素直な壊れ方。
void main() {
  final url = Uri.parse('https://example.com/preset-servers/');

  /// リンクになっている（`recognizer` を持つ）span を集める。
  List<TextSpan> linkedSpans(WidgetTester tester) {
    final rich = tester.widget<RichText>(
      find.descendant(
        of: find.byType(TermLinkText),
        matching: find.byType(RichText),
      ),
    );
    final found = <TextSpan>[];
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.recognizer != null) found.add(span);
      return true;
    });
    return found;
  }

  String plainText(WidgetTester tester) {
    final rich = tester.widget<RichText>(
      find.descendant(
        of: find.byType(TermLinkText),
        matching: find.byType(RichText),
      ),
    );
    return rich.text.toPlainText();
  }

  Future<void> pump(WidgetTester tester, String text) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TermLinkText(text: text, term: 'プリセットサーバー', url: url),
        ),
      ),
    );
  }

  group('段落の中の 1 語がリンクになる', () {
    testWidgets('語が 1 回出る段落', (tester) async {
      const text = 'プッシュ通知は、プリセットサーバーのアカウントが要ります。';
      await pump(tester, text);

      expect(linkedSpans(tester).length, 1);
      expect(linkedSpans(tester).single.text, 'プリセットサーバー');
      // ⚠ 前後が落ちていない。
      expect(plainText(tester), text);
    });

    testWidgets('⚠⚠ 語が 2 回出ても光るのは最初の 1 回だけ', (tester) async {
      const text =
          'プリセットサーバー以外でも受け取れます。'
          'プリセットサーバーをお使いの方は、これまでどおりです。';
      await pump(tester, text);

      // 🔴 全部の出現をリンクにする実装だと 2 になる（#1221 の完了条件）。
      expect(linkedSpans(tester).length, 1);
      expect(plainText(tester), text);
    });

    testWidgets('語が段落の先頭に来ても文字が落ちない', (tester) async {
      const text = 'プリセットサーバーのアカウントが登録されています。';
      await pump(tester, text);

      expect(plainText(tester), text);
      expect(linkedSpans(tester).length, 1);
    });

    testWidgets('語が段落の末尾に来ても文字が落ちない', (tester) async {
      const text = '無償で使えるのはプリセットサーバー';
      await pump(tester, text);

      expect(plainText(tester), text);
      expect(linkedSpans(tester).length, 1);
    });
  });

  group('⚠ 語が無い文面でも壊れない', () {
    testWidgets('状態で差し替わる文面に語が無ければ、ただの Text として描く', (tester) async {
      // プッシュ通知設定画面の (false, true) の文面は語を含まない。
      const text = 'プッシュ通知リレーの利用権があるため、利用できます。';
      await pump(tester, text);

      expect(find.text(text), findsOneWidget);
      // ⚠ 素の [Text] も内部で [RichText] を作るので、**ウィジェットの有無では
      // 判定できない。**光っていないこと（recognizer が無いこと）で見る。
      expect(linkedSpans(tester), isEmpty);
      expect(plainText(tester), text);
    });
  });

  group('⚠ 歯があることを、実際に穴を開けて確かめる', () {
    test('「最初の 1 回だけ」を判定している indexOf が、2 回目を拾わない', () {
      const text = 'プリセットサーバー以外でも。プリセットサーバーをお使いの方は。';
      const term = 'プリセットサーバー';

      // 実装が使っている形。
      expect(text.indexOf(term), 0);
      // 🔴 `lastIndexOf` へ取り違えると、光る位置が 2 回目へ動く。
      expect(text.lastIndexOf(term), isNot(text.indexOf(term)));
    });

    test('語が無ければ -1 ＝ Text へ落ちる分岐に入る', () {
      expect('利用権があるため。'.indexOf('プリセットサーバー'), -1);
    });
  });
}

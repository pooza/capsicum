import 'package:capsicum/src/ui/util/text_length_counter.dart';
import 'package:capsicum/src/util/post_text_length.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1035-E5: 上限のない入力欄にカウンタを出さない。
///
/// Flutter は `maxLength` が null でも `buildCounter` を呼ぶ
/// （`text_field.dart` の `_buildCounter`）。カウンタ側で分岐しないと、
/// ドライブの「名前の変更」「フォルダを作成」のような**上限のない欄に、
/// 上限の無い裸の数字**が出る。害はないが意図した表示ではない。
void main() {
  /// [serverLengthCounter] が返す widget を、`buildCounter` と同じ引数で作る。
  Widget? build(
    WidgetTester tester,
    BuildContext context,
    String text,
    int? maxLength, {
    int Function(String text)? count,
  }) {
    final controller = TextEditingController(text: text);
    addTearDown(controller.dispose);
    return serverLengthCounter(controller, count: count)(
      context,
      currentLength: text.characters.length,
      isFocused: true,
      maxLength: maxLength,
    );
  }

  /// `buildCounter` を呼べる BuildContext を 1 つ用意する。
  Future<BuildContext> pumpContext(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      ),
    );
    return ctx;
  }

  testWidgets('上限があれば「現在 / 上限」を出す', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      ),
    );

    final counter = build(tester, ctx, '👨‍👩‍👧‍👦', 512);
    expect(counter, isA<Text>());
    expect(
      (counter! as Text).data,
      '7 / 512',
      reason: '数えるのはサーバーと同じコードポイント。書記素なら 1 になる',
    );
  });

  testWidgets('上限が無ければ何も出さない (#1035-E5)', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      ),
    );

    expect(
      build(tester, ctx, 'abc', null),
      isNull,
      reason: 'null を返せば Flutter の既定（カウンタ無し）に戻る',
    );
  });

  group('数え方を差し替えられる (#1034)', () {
    // ⚠⚠ **本文と同じ上限を当てる欄は、数え方も backend で変わる。**
    // ALT（既定のコードポイント）と同じ関数を使いながら、テンプレの本文欄だけは
    // Mastodon の規則（書記素 + URL 23 文字）で数える必要がある。
    testWidgets('⚠⚠ count を渡すとその規則で数える', (tester) async {
      final ctx = await pumpContext(tester);
      const url = 'https://example.com/watch?v=0123456789abcdef';
      expect(url.length, 44, reason: '前提: 素の文字数');

      final counter = build(
        tester,
        ctx,
        url,
        500,
        count: (text) =>
            postTextLength(PostLengthRule.shortenedGraphemes, text),
      );

      expect((counter! as Text).data, '23 / 500', reason: 'URL は一律 23 文字');
    });

    testWidgets('既定はコードポイント（ALT 欄はこのまま）', (tester) async {
      final ctx = await pumpContext(tester);

      final counter = build(tester, ctx, '👨‍👩‍👧‍👦', 512);

      expect((counter! as Text).data, '7 / 512');
    });
  });
}

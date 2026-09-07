import 'package:capsicum/src/ui/util/text_length_counter.dart';
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
    int? maxLength,
  ) {
    final controller = TextEditingController(text: text);
    addTearDown(controller.dispose);
    return serverLengthCounter(controller)(
      context,
      currentLength: text.characters.length,
      isFocused: true,
      maxLength: maxLength,
    );
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
}

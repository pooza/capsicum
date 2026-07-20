import 'package:capsicum/src/ui/flash/flash_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

FlashRuntime _runtime() => FlashRuntime(
  flashId: 'flash1',
  host: 'misskey.example',
  customEmojis: const [
    (name: 'dai_smile', category: 'ダイ大'),
    (name: 'gomechan', category: 'ダイ大'),
    (name: 'nocategory', category: null),
  ],
  userId: 'user1',
  userName: 'pooza',
  userUsername: 'pooza',
);

void main() {
  group('FlashRuntime (#830)', () {
    test('Ui:render がルートの子を id 参照で組み立てる', () async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);

      await runtime.run('''
        let text = Ui:C:mfm({ text: "\$[tada こんにちは]" }, "greeting")
        Ui:render([
          Ui:C:container({ children: [text], align: "center" }, "root_box")
        ])
      ''');

      expect(runtime.rootChildren, ['root_box']);

      final container = runtime.component('root_box')!;
      expect(container.type, 'container');
      expect(container.props['align'], 'center');
      // children は入れ子オブジェクトではなく id の配列。
      expect(container.children, ['greeting']);

      final mfm = runtime.component('greeting')!;
      expect(mfm.type, 'mfm');
      expect(mfm.text, contains('こんにちは'));
    });

    test('Ui:get(...).update は def にあるキーだけを上書きする', () async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);

      await runtime.run('''
        Ui:render([
          Ui:C:text({ text: "before", bold: true, size: 20 }, "t")
        ])
        Ui:get("t").update({ text: "after" })
      ''');

      final text = runtime.component('t')!;
      expect(text.text, 'after');
      // 未指定のキーが既定値で潰れないこと。
      expect(text.props['bold'], isTrue);
      expect(text.props['size'], 20);
    });

    test('update でリスナーに通知する', () async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);

      var notified = 0;
      runtime.addListener(() => notified++);

      await runtime.run('''
        Ui:render([Ui:C:text({ text: "a" }, "t")])
        Ui:get("t").update({ text: "b" })
      ''');

      expect(notified, greaterThan(0));
    });

    test('button の onClick を invoke でき、結果がツリーに反映される', () async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);

      await runtime.run('''
        var count = 0
        let label = Ui:C:text({ text: "0" }, "label")
        let btn = Ui:C:button({
          text: "押す"
          onClick: @() {
            count = count + 1
            Ui:get("label").update({ text: `{count}` })
          }
        }, "btn")
        Ui:render([label, btn])
      ''');

      expect(runtime.component('label')!.text, '0');

      final onClick = runtime.component('btn')!.props['onClick'];
      await runtime.invoke(onClick);
      expect(runtime.component('label')!.text, '1');

      await runtime.invoke(onClick);
      expect(runtime.component('label')!.text, '2');
    });

    test('CUSTOM_EMOJIS をスクリプトから参照できる', () async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);

      // 絵文字ガチャ系の実在 Play が category で絞り込んで使う経路。
      await runtime.run('''
        let dai = CUSTOM_EMOJIS.filter(@(e) { e.category == "ダイ大" })
        let names = dai.map(@(e) { e.name })
        Ui:render([Ui:C:text({ text: names.join(",") }, "t")])
      ''');

      expect(runtime.component('t')!.text, 'dai_smile,gomechan');
    });

    test('未実装の Ui:C:* は「capsicum が未対応」に分類する', () async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);

      // スクリプトの不具合ではなくバインディング層の不足なので、そう伝わる
      // 文言でなければならない。
      await expectLater(
        runtime.run('Ui:render([Ui:C:canvas({ width: 10, height: 10 }, "c")])'),
        throwsA(
          isA<FlashRuntimeError>()
              .having((e) => e.summary, 'summary', contains('未対応'))
              .having((e) => e.detail, 'detail', contains('Ui:C:canvas')),
        ),
      );
    });

    test('構文エラーは読み込み失敗として扱う', () async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);

      await expectLater(
        runtime.run('let = = ='),
        throwsA(
          isA<FlashRuntimeError>().having(
            (e) => e.summary,
            'summary',
            contains('読み込めませんでした'),
          ),
        ),
      );
    });

    test('空のスクリプトは実行しない', () async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);

      await expectLater(runtime.run(''), throwsA(isA<FlashRuntimeError>()));
    });

    test('dispose 後の invoke はツリーを触らない', () async {
      final runtime = _runtime();

      await runtime.run('''
        Ui:render([
          Ui:C:button({
            text: "押す"
            onClick: @() { Ui:get("label").update({ text: "clicked" }) }
          }, "btn")
          Ui:C:text({ text: "before" }, "label")
        ])
      ''');

      final onClick = runtime.component('btn')!.props['onClick'];
      runtime.dispose();
      await runtime.invoke(onClick);

      expect(runtime.component('label')!.text, 'before');
    });
  });
}

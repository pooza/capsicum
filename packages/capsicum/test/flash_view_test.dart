import 'package:capsicum/src/ui/flash/flash_runtime.dart';
import 'package:capsicum/src/ui/flash/flash_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

FlashRuntime _runtime() => FlashRuntime(
  flashId: 'flash1',
  host: 'misskey.example',
  customEmojis: const [],
);

Future<void> _pump(WidgetTester tester, FlashRuntime runtime) {
  return tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: FlashView(runtime: runtime)),
        ),
      ),
    ),
  );
}

void main() {
  group('FlashView (#830)', () {
    testWidgets('container の入れ子を id 参照でたどって描画する', (tester) async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);
      await runtime.run('''
        let inner = Ui:C:text({ text: "なかみ" }, "inner")
        Ui:render([Ui:C:container({ children: [inner] }, "box")])
      ''');

      await _pump(tester, runtime);

      expect(find.text('なかみ'), findsOneWidget);
    });

    testWidgets('hidden のコンポーネントは描画しない', (tester) async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);
      await runtime.run('''
        Ui:render([Ui:C:text({ text: "みえない", hidden: true }, "t")])
      ''');

      await _pump(tester, runtime);

      expect(find.text('みえない'), findsNothing);
    });

    testWidgets('button を押すとスクリプトが走り、表示が更新される', (tester) async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);
      await runtime.run('''
        let label = Ui:C:text({ text: "0" }, "label")
        let btn = Ui:C:button({
          text: "押す"
          onClick: @() { Ui:get("label").update({ text: "1" }) }
        }, "btn")
        Ui:render([label, btn])
      ''');

      await _pump(tester, runtime);
      expect(find.text('0'), findsOneWidget);

      await tester.tap(find.text('押す'));
      await tester.pumpAndSettle();

      expect(find.text('1'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('disabled な button は押せない', (tester) async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);
      await runtime.run('''
        let label = Ui:C:text({ text: "before" }, "label")
        let btn = Ui:C:button({
          text: "押す"
          disabled: true
          onClick: @() { Ui:get("label").update({ text: "after" }) }
        }, "btn")
        Ui:render([label, btn])
      ''');

      await _pump(tester, runtime);
      await tester.tap(find.text('押す'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.text('before'), findsOneWidget);
    });

    testWidgets('buttons は定義配列をそのまま並べる', (tester) async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);
      // buttons は children と違い id 参照ではなく button 定義の配列で来る。
      await runtime.run('''
        Ui:render([
          Ui:C:buttons({
            buttons: [
              { text: "いち", onClick: @() {} }
              { text: "に", onClick: @() {} }
            ]
          }, "bs")
        ])
      ''');

      await _pump(tester, runtime);

      expect(find.text('いち'), findsOneWidget);
      expect(find.text('に'), findsOneWidget);
    });

    testWidgets('postFormButton はラベルを出す', (tester) async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);
      await runtime.run('''
        Ui:render([
          Ui:C:postFormButton({
            text: "結果を投稿"
            primary: true
            form: { text: "きょうの運勢は大吉" }
          }, "post")
        ])
      ''');

      await _pump(tester, runtime);

      expect(find.text('結果を投稿'), findsOneWidget);
    });

    testWidgets('postFormButton は align によらず常に中央に置く (#830)', (tester) async {
      // root 直下（Column が stretch）に置くと、Align が無ければボタンは全幅に
      // 伸びてしまう。Align(center) で「全幅にせず中央」を固定する。
      final runtime = _runtime();
      addTearDown(runtime.dispose);
      await runtime.run('''
        Ui:render([
          Ui:C:postFormButton({ text: "投稿する", primary: true }, "post")
        ])
      ''');

      await _pump(tester, runtime);

      final buttonSize = tester.getSize(find.byType(FilledButton));
      final viewWidth = tester.getSize(find.byType(FlashView)).width;
      // 全幅に伸びていない（stretch されていない）。
      expect(buttonSize.width, lessThan(viewWidth));
      // 中央にある。
      final buttonCenter = tester.getCenter(find.byType(FilledButton)).dx;
      final viewCenter = tester.getCenter(find.byType(FlashView)).dx;
      expect((buttonCenter - viewCenter).abs(), lessThan(1.0));
    });

    // mfm の Text.rich を拾う（button ラベル / text は data 付き Text、mfm だけ
    // textSpan 付き）。
    TextAlign? mfmTextAlign(WidgetTester tester) {
      final finder = find.byWidgetPredicate(
        (w) => w is Text && w.textSpan != null,
      );
      if (finder.evaluate().isEmpty) return null;
      return tester.widget<Text>(finder.first).textAlign;
    }

    testWidgets('align 未指定の container は mfm を左寄せのままにする (#876)', (tester) async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);
      await runtime.run('''
        Ui:render([
          Ui:C:container({ children: [Ui:C:mfm({ text: "リール" }, "m")] }, "box")
        ])
      ''');

      await _pump(tester, runtime);

      expect(mfmTextAlign(tester), TextAlign.start);
    });

    testWidgets('align:center の container は mfm の各行を中央寄せする (#876)', (
      tester,
    ) async {
      // スロット系 Play は中央 container の中で、横倒しリール行と結果テキスト行
      // という幅の異なる行を並べる。行内で中央寄せしないと、paint-only の rotate
      // リールが結果行に対して左へずれて食み出す。
      final runtime = _runtime();
      addTearDown(runtime.dispose);
      await runtime.run('''
        Ui:render([
          Ui:C:container({
            align: "center"
            children: [Ui:C:mfm({ text: "リール" }, "m")]
          }, "box")
        ])
      ''');

      await _pump(tester, runtime);

      expect(mfmTextAlign(tester), TextAlign.center);
    });

    testWidgets('align は入れ子 container の子 mfm へも継承する (#876)', (tester) async {
      // 本家 Misskey の text-align は子孫へ継承する。align 未指定の入れ子でも
      // 祖先の center を引き継ぐ。
      final runtime = _runtime();
      addTearDown(runtime.dispose);
      await runtime.run('''
        let inner = Ui:C:container({
          children: [Ui:C:mfm({ text: "リール" }, "m")]
        }, "inner")
        Ui:render([
          Ui:C:container({ align: "center", children: [inner] }, "outer")
        ])
      ''');

      await _pump(tester, runtime);

      expect(mfmTextAlign(tester), TextAlign.center);
    });

    testWidgets('循環参照でも無限再帰しない', (tester) async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);
      // スクリプトが自分自身を子に入れても描画が止まること。
      await runtime.run('''
        let box = Ui:C:container({ children: [] }, "box")
        Ui:get("box").update({ children: [box] })
        Ui:render([box])
      ''');

      await _pump(tester, runtime);

      expect(tester.takeException(), isNull);
    });
  });
}

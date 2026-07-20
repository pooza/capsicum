import 'package:aiscript/aiscript.dart';
import 'package:flutter_test/flutter_test.dart';

/// AiScript ランタイム (#830) が capsicum のパッケージ解決内で動くことの
/// smoke test。フォーク (pooza/aiscript-dart) の ref を上げたときに、
/// 依存解決だけ通って実行が壊れている状態を検出する。
void main() {
  group('AiScript ランタイム (#830)', () {
    test('スクリプトをパースして実行できる', () async {
      final res = Parser().parse('<: 1 + 2');

      Value? printed;
      final state = Interpreter({}, printFn: (v) => printed = v);
      state.source = res.source;
      await state.exec(res.ast);

      expect(printed, isA<NumValue>());
      expect((printed! as NumValue).value, 3);
    });

    test('ホスト側の native 関数を注入できる', () async {
      // Flash の Ui: / Mk: 標準ライブラリは、この経路で Flutter 側の実装を
      // 差し込む。バインディング層の前提が壊れていないことを確認する。
      final rendered = <String>[];
      final res = Parser().parse('Ui:render("hello")');
      final state = Interpreter({
        'Ui:render': NativeFnValue((args, _) async {
          rendered.add(args.check<StrValue>(0).value);
          return NullValue();
        }),
      });
      state.source = res.source;
      await state.exec(res.ast);

      expect(rendered, ['hello']);
    });

    test('Arr#slice が範囲外でも例外を投げない', () async {
      // 実在の Flash が空配列に slice(0 n) を呼んでクラッシュした回帰
      // (フォーク側で JS 準拠にクランプ済み)。
      final res = Parser().parse('''
        let empty = []
        <: empty.slice(0, 10).len
      ''');

      Value? printed;
      final state = Interpreter({}, printFn: (v) => printed = v);
      state.source = res.source;
      await state.exec(res.ast);

      expect((printed! as NumValue).value, 0);
    });
  });
}

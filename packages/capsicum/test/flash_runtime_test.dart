import 'dart:convert';
import 'dart:io';

import 'package:aiscript/aiscript.dart';
import 'package:capsicum/src/ui/flash/flash_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// フォーク (pooza/aiscript-dart) の中で乱数を引いている箇所の既知の全量 (#960)。
///
/// `<ファイル名>:<直前の組み込み名>` の形。`<top-level>` は組み込みの外側で、
/// `stdlib.dart` の `final _rng = Random();` と `const _uuid = Uuid();` の宣言に
/// 当たる。`Util:uuid` は乱数だが「出目」ではない識別子生成なので
/// [FlashRuntime.usesRandomness] の対象から意図的に外している（これを拾うと
/// コンポーネント id に uuid を振るだけの Play にまで注記が出る）。
const _knownRandomnessSites = {
  'stdlib.dart:<top-level>',
  'stdlib.dart:Math:rnd',
  'stdlib.dart:Math:gen_rng',
  'stdlib.dart:Util:uuid',
};

/// 乱数の入口になりうる字面。`Random` の直接生成のほか、内部で暗黙に乱数を使う
/// `List.shuffle` と uuid 生成も見る。
const _randomnessTokens = [
  'Random(',
  '_rng',
  'SeedRandom(',
  '.shuffle(',
  'Uuid(',
  '_uuid',
];

/// 組み込みのキー行（`'Math:rnd':` / `'shuffle':`）。
final _builtinKeyPattern = RegExp(r"^\s*'([A-Za-z0-9_:]+)'\s*:");

/// pub-cache に展開されたフォークの `lib/` を指す。
///
/// `Isolate.resolvePackageUri` は flutter_tester では動かない
/// （Unsupported operation）ので、melos ワークスペース root の
/// `.dart_tool/package_config.json` を辿る。
Directory _aiscriptLibDir() {
  var dir = Directory.current;
  while (true) {
    final config = File('${dir.path}/.dart_tool/package_config.json');
    if (config.existsSync()) {
      final packages =
          (jsonDecode(config.readAsStringSync())
                  as Map<String, dynamic>)['packages']
              as List<dynamic>;
      final aiscript = packages.cast<Map<String, dynamic>>().firstWhere(
        (p) => p['name'] == 'aiscript',
        orElse: () =>
            throw StateError('${config.path} に aiscript が無い（pub get 未実行？）'),
      );
      // rootUri は package_config.json のあるディレクトリからの相対でもありうる。
      final root = config.uri.resolve(aiscript['rootUri'] as String);
      return Directory.fromUri(root.resolve('lib/'));
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('package_config.json が見つからない (${Directory.current})');
    }
    dir = parent;
  }
}

/// フォークの lib/ を実際に読んで、乱数を引いている箇所を洗い出す。
///
/// `seedrandom.dart` は乱数生成器そのものの実装なので対象外（ここに
/// `Random` 相当が出るのは定義上あたりまえで、組み込みの増減を表さない）。
Set<String> _randomnessSitesInFork() {
  final libDir = _aiscriptLibDir();
  expect(libDir.existsSync(), isTrue, reason: '${libDir.path} が無い');

  final sites = <String>{};
  final sources =
      libDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in sources) {
    final name = file.uri.pathSegments.last;
    if (name == 'seedrandom.dart') continue;

    var current = '<top-level>';
    for (final line in file.readAsLinesSync()) {
      final key = _builtinKeyPattern.firstMatch(line);
      if (key != null) current = key.group(1)!;
      if (_randomnessTokens.any(line.contains)) sites.add('$name:$current');
    }
  }
  return sites;
}

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

    test('require() はモジュール解決できない（FileModuleResolver 非注入の固定 #872）', () async {
      // capsicum は Interpreter に FileModuleResolver を渡さず、既定の
      // DummyModuleResolver に委ねることで、サーバー由来スクリプトからの
      // ファイル/モジュール読み込みを構造的に塞いでいる。サンドボックス健全性は
      // この「moduleResolver を注入しない」1 点に依存するため、誤って注入する
      // 回帰をここで検知する。
      final runtime = _runtime();
      addTearDown(runtime.dispose);

      await expectLater(
        runtime.run('require("./secret")'),
        throwsA(
          isA<FlashRuntimeError>().having(
            (e) => e.detail,
            'detail',
            contains('module'),
          ),
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

    test('engineLangVersion が評価器の Core:v と一致する (#934)', () async {
      // degrade の文言にこの数値を出す以上、定数がフォークの実体からずれると
      // 「事実を書く」という前提が崩れる。フォークの ref を上げたときにここで
      // 落ちるようにしておく。
      final interpreter = Interpreter({});
      String? printed;
      interpreter.printFn = (value) => printed = (value as StrValue).value;
      await interpreter.exec(Parser().parse('<: Core:v').ast);

      expect(printed, FlashRuntime.engineLangVersion);
    });
  });

  group('usesRandomness (#935)', () {
    test('Math:rnd を使う Play を拾う', () {
      expect(FlashRuntime.usesRandomness('let n = Math:rnd(0 10)'), isTrue);
    });

    test('Math:gen_rng を使う Play を拾う', () {
      expect(
        FlashRuntime.usesRandomness('let r = Math:gen_rng("seed")'),
        isTrue,
      );
    });

    test('乱数を使わない Play は拾わない', () {
      expect(
        FlashRuntime.usesRandomness(
          'Ui:render([Ui:C:text({ text: "a" }, "t")])',
        ),
        isFalse,
      );
    });

    test('Math:round は Math:rnd と紛れない', () {
      expect(FlashRuntime.usesRandomness('let n = Math:round(1.5)'), isFalse);
    });

    /// 評価器の乱数源はこの 2 つだけ、というのが判定の前提。フォークが乱数を
    /// 使う組み込みを増やしたらここが落ちるので、判定側も足す。
    ///
    /// 実装と同じ文字列を `usesRandomness` に食わせて true を確かめるだけでは、
    /// フォークの stdlib を一切見ていないので常に通ってしまう（#960）。
    /// pub-cache に展開されたフォークの実体を読み、乱数プリミティブを引いて
    /// いる箇所を洗い出して突き合わせる。
    test('評価器の乱数源はこの 2 つだけ（フォークの stdlib を実測 #960）', () {
      final found = _randomnessSitesInFork();

      expect(
        found,
        _knownRandomnessSites,
        reason:
            'フォーク (pubspec の aiscript ref) が乱数を引く箇所を増減させた。'
            '出目に効く組み込みなら FlashRuntime.usesRandomness に足し、'
            '効かないなら理由を添えて _knownRandomnessSites を更新する',
      );

      // 出目に効く組み込みは判定側が拾えていること。
      for (final name in ['Math:rnd', 'Math:gen_rng']) {
        expect(
          FlashRuntime.usesRandomness('let x = $name(0 10)'),
          isTrue,
          reason: '$name を乱数源として数えている',
        );
      }
    });
  });

  group('Math:gen_rng が Misskey Web と同じ出目を出す (#896)', () {
    /// 期待値は本物の seedrandom 3.0.5（本家 aiscript 0.19.0 が使う版）を Node で
    /// 回した実測値。フォーク側にも同じ固定があるが、**pin を上げたときに
    /// capsicum の CI で気づける**ようここにも置く。ここが落ちたら、シードを
    /// 固定しても Web と出目が一致しない状態に戻っている。
    Future<String> drawnBy(FlashRuntime runtime, String seedExpr) async {
      await runtime.run('''
        let r = Math:gen_rng($seedExpr)
        var s = ""
        for (let i, 5) {
          s = `{s},{r(0 100000)}`
        }
        Ui:render([Ui:C:text({ text: s }, "t")])
      ''');
      return runtime.component('t')!.text!;
    }

    test('実在の Play が使う形のシード', () async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);

      expect(
        await drawnBy(runtime, '"user12345_2026_7_26_comfy_slot"'),
        ',51954,23544,4594,30169,42535',
      );
    });

    test('数値シードは JS と同じ文字列化を経る', () async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);

      // 本家は seed.value.toString() を渡すので 5 と "5" は同値。
      expect(await drawnBy(runtime, '5'), ',7790,71777,69339,58096,31513');
    });
  });

  group('run() は非同期コールバックを待たない (#898)', () {
    // 出目をアニメーションで出す Play（スロット系）を模す。トップレベルは
    // Async:timeout を仕掛けて即座に終わり、確定した出目はコールバックの中で
    // 初めてツリーに載る。
    const animated = '''
      let random = Math:gen_rng("seed_fixed")
      let box = Ui:C:mfm({ text: "とちゅう" }, "reel")
      Ui:render([box])

      @finish() {
        Ui:get("reel").update({ text: `かくてい{random(0 9)}` })
      }
      Async:timeout(10 finish)
    ''';

    test('run() 直後はまだ途中経過が載っている', () async {
      final runtime = _runtime();
      addTearDown(runtime.dispose);

      await runtime.run(animated);

      // ここで指紋を取ると「出目」ではなく途中経過を測ることになる。これが
      // 2026-08-10 の突合で判明した計測器の不備の正体（#898）。
      expect(runtime.component('reel')!.text, 'とちゅう');
    });

    test('落ち着くまで待てば確定した出目が載り、同じシードなら再実行でも一致する', () async {
      Future<String> settledText() async {
        final runtime = _runtime();
        addTearDown(runtime.dispose);
        await runtime.run(animated);
        // Async:timeout のコールバックが載るまで待つ。
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return runtime.component('reel')!.text!;
      }

      final first = await settledText();
      final second = await settledText();

      expect(first, startsWith('かくてい'));
      // シードが同じなら出目も同じ。ここが割れるなら乱数側の回帰。
      expect(first, second);
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #1184: docs の表記規約とファイルサイズを機械で見る検査。
///
/// ## なぜ要るか
///
/// 2 つとも **一度掃除しても必ず戻る**種類の崩れで、しかも**崩れても誰も困らない
/// ふりをして進む**（ビルドは通るし、アプリも動く）。
///
/// ### 1. 見出しの先頭に `⚠` を付けない
///
/// GitHub はアンカーを作るときに記号を落とすので、`### ⚠⚠ develop が…` は
/// `#-develop-…` という**先頭にハイフンが残る**綴りになる。同じ文書内からの
/// リンクが前例のない形になり、2026-09-17 に #1142 で実際に踏んだ。
/// 規約は [docs/CLAUDE.md]「ドキュメント表記規約」にあり、**強調は本文 1 行目へ
/// 移す**。2026-09-30 の #1184 で、規約化より前の **58 件**（docs 直下 44 /
/// docs/archive 10 / .claude/skills 4）を直した。
///
/// ⚠⚠ **フェンスの中を見てはいけない。**`docs/dev-environment.md` と
/// `.claude/skills/store-release/build-upload.md` には、シェルのコメントとして
/// `# ⚠ …` で始まる行が**実在する**。素朴な `grep '^#\{1,6\} ⚠'` は 2 件を
/// 誤検出するので、**この検査が通ったことを「grep が 0 件」で確かめてはいけない**。
///
/// ### 2. 1 ファイルの大きさ
///
/// ⚠⚠ **上限の根拠は Read の 25,000 トークン。**このリポジトリの docs は
/// **約 2.55 バイト / トークン**で、`deck-ui-plan.md` を 64,720 バイトまで削った
/// 時点でも **25,383 トークン**あり、**1 回では読めなかった**（2026-09-30 実測）。
/// → **1 回で読める上限は約 63.7KB**。[_threshold] の 60,000 はそこへ余裕を
/// 持たせた値で、⚠ **推定ではなく実測から来ている**（当初 65KB と見積もって外した）。
///
/// 読めないファイルは「読まずに書く」を誘発する。⚠ 実際に #1184 の直前まで
/// `deck-ui-plan.md` は 100,600 バイトあり、**節番号を名前で参照しているコードが
/// あるのに全文を確かめられない**状態だった。
///
/// ## ⚠⚠ この形の検査は、判定が壊れても緑になる
///
/// `expect(offenders, isEmpty)` は**何も見ていなくても通る**。そのため
/// docs/CLAUDE.md「[ソース検査ガードの書き方]」の 3 点セットを同じファイルに置く。
///
/// 1. **走査が空振りしていないこと** — ファイル数・見出しの総数・既知のファイルが
///    列挙に入ること・**フェンス内の実物が誤検出されないこと**
/// 2. **判定ロジックに合成ソースを食わせる** — 当たる形と、当ててはいけない形
/// 3. **穴を開けて歯を確認する** — 直す前の実物の綴りを食わせて落ちること、
///    サイズ側は超過・stale な exemption の両方で落ちること
void main() {
  // ⚠ テストの cwd は `packages/capsicum`（CI も `cd "$pkg" && flutter test`）。
  // リポジトリルートはその 2 つ上。
  const repoRoot = '../..';
  const docsDir = '$repoRoot/docs';
  const skillsDir = '$repoRoot/.claude/skills';

  late List<File> headingScanFiles;
  late List<File> sizeScanFiles;

  setUpAll(() {
    expect(
      Directory(docsDir).existsSync(),
      isTrue,
      reason: '⚠ $docsDir が見つからない。テストの cwd が変わったらこの相対パスも直す',
    );
    expect(
      Directory(skillsDir).existsSync(),
      isTrue,
      reason: '⚠ $skillsDir が見つからない',
    );

    // 見出しの規約は docs も skills も、archive も対象。アンカーの壊れ方は
    // 「現役かどうか」と関係ないため。
    headingScanFiles = [
      ..._markdownFiles(docsDir),
      ..._markdownFiles(skillsDir),
    ];

    // ⚠ サイズは docs の**直下だけ**。`docs/archive/` は「過去の記録・現役運用
    // では参照しない」と docs/CLAUDE.md が定義しているので、1 回で読める必要が
    // ない（`archive/release-log.md` は 112KB ある）。⚠⚠ **逃がし先がここなので、
    // archive を対象に入れると案 A そのものが成立しなくなる。**
    sizeScanFiles = Directory(docsDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.md'))
        .toList();
  });

  group('見出しの先頭に ⚠ を付けない (#1184)', () {
    test('docs と skills の見出しが ⚠ で始まっていない', () {
      final offenders = <String>[];
      for (final file in headingScanFiles) {
        for (final v in scanWarningHeadings(file.readAsStringSync())) {
          offenders.add('${file.path}:${v.line}\t${v.text}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            '⚠⚠ 見出しの先頭に `⚠` / `⚠⚠` を付けないこと。GitHub のアンカーが '
            '`#-…` という先頭ハイフン付きの綴りになり、同じ文書内からのリンクが '
            '壊れる（#1142 で実際に踏んだ）。**強調は本文 1 行目へ移す**\n'
            '${offenders.join('\n')}',
      );
    });
  });

  group('1 ファイルは 1 回で読める大きさに収める (#1184)', () {
    test('docs 直下が閾値か記録済み budget の内側にある', () {
      final sizes = {
        for (final f in sizeScanFiles) f.uri.pathSegments.last: f.lengthSync(),
      };
      expect(
        scanSizeViolations(
          sizes: sizes,
          budgets: _budgets,
          threshold: _threshold,
        ),
        isEmpty,
        reason:
            '⚠⚠ 1 回で読める上限は約 63.7KB（実測・2.55 バイト/トークン）。'
            '超えると「読まずに書く」が始まる。**落ち着いた節を '
            '`docs/archive/` へ移す**のが既定の直し方で、'
            '⚠ **節番号は振り直さない**（コードのコメントが名前で参照している）。'
            '⚠⚠ **手順は `/doc-maintenance` の step 6。**'
            'この赤は「棚卸しが要る」という合図',
      );
    });
  });

  // ⚠ ここから下は「検査が動いていること」そのものの検査。
  group('⚠ 走査が空振りしていない', () {
    test('走査したファイル数が実態と合っている', () {
      // 2026-09-30 時点で docs 38（直下 23 + archive 15）/ skills 13。
      // ⚠ **下限を固定する。**0 件でも `isEmpty` は通ってしまう。
      expect(headingScanFiles.length, greaterThanOrEqualTo(45));
      expect(sizeScanFiles.length, greaterThanOrEqualTo(20));
    });

    test('既知のファイルが列挙に入っている', () {
      final paths = headingScanFiles.map((f) => f.path).toList();
      expect(paths, contains('$docsDir/CLAUDE.md'));
      expect(paths, contains('$docsDir/archive/deck-ui-plan-settled.md'));
      expect(paths, contains('$skillsDir/store-release/SKILL.md'));
      // ⚠ サイズ側は archive を含まない。これは意図で、漏れではない。
      expect(
        sizeScanFiles.map((f) => f.path),
        isNot(contains('$docsDir/archive/release-log.md')),
      );
    });

    test('見出しそのものが見えている', () {
      // 見出しを 1 つも認識できていなければ、違反が 0 件なのは当たり前。
      final headings = headingScanFiles.fold<int>(
        0,
        (sum, f) => sum + _countHeadings(f.readAsStringSync()),
      );
      expect(
        headings,
        greaterThanOrEqualTo(700),
        reason: '2026-09-30 時点で 974 件',
      );
    });

    test('⚠⚠ フェンス内の `# ⚠ …` が実在し、しかも誤検出されない', () {
      // ⚠ これが「grep では 45 件出るが 1 件は誤検出」の正体。合成ソースではなく
      // **実物**で確かめる（2 本ある）。
      for (final path in const [
        '$docsDir/dev-environment.md',
        '$skillsDir/store-release/build-upload.md',
      ]) {
        final source = File(path).readAsStringSync();
        expect(
          RegExp(r'^#{1,6} ⚠', multiLine: true).hasMatch(source),
          isTrue,
          reason:
              '⚠ $path のフェンス内にあった `# ⚠ …` が消えた。'
              'この検査はフェンスを飛ばすことを実物で確かめる足場を失うので、'
              '別の実物へ差し替えるか、この足場ごと畳む',
        );
        expect(
          scanWarningHeadings(source),
          isEmpty,
          reason: '⚠⚠ $path を誤検出している',
        );
      }
    });
  });

  group('⚠ 判定ロジックに合成ソースを食わせる', () {
    test('見出し: 当てるべき形', () {
      expect(scanWarningHeadings('# ⚠ だめ'), hasLength(1));
      expect(scanWarningHeadings('###### ⚠⚠ だめ'), hasLength(1));
      // 全角スペース・空白なしでも当てる（綴りの揺れで逃がさない）。
      expect(scanWarningHeadings('## ⚠だめ'), hasLength(1));
      expect(scanWarningHeadings('##   ⚠ だめ'), hasLength(1));
      expect(scanWarningHeadings('# ⚠ 1 件目\n\n# ⚠ 2 件目'), hasLength(2));
    });

    test('見出し: 当ててはいけない形', () {
      expect(scanWarningHeadings('## よい見出し'), isEmpty);
      // 見出しの**途中**の ⚠ は対象外。アンカー先頭にハイフンは出ない。
      expect(scanWarningHeadings('## よい見出し（⚠⚠ 補足）'), isEmpty);
      // 本文 1 行目へ移した形 —— これが規約の着地点。
      expect(scanWarningHeadings('## よい見出し\n\n⚠⚠ **強調は本文へ。**'), isEmpty);
      // 見出しではない `#`（Markdown は `#` の直後に空白か終端が要る）。
      expect(scanWarningHeadings('#⚠ タグのようなもの'), isEmpty);
      expect(scanWarningHeadings('####### ⚠ 7 個は見出しではない'), isEmpty);
      // 行頭でなければ見出しではない。
      expect(scanWarningHeadings('本文の途中に # ⚠ が出ても見出しではない'), isEmpty);
    });

    test('見出し: フェンスの中は飛ばす', () {
      expect(scanWarningHeadings('```sh\n# ⚠ シェルのコメント\n```'), isEmpty);
      expect(scanWarningHeadings('~~~\n# ⚠ 別の綴りのフェンス\n~~~'), isEmpty);
      // ⚠ 開いた記号と違う記号では閉じない。閉じたと誤認すると、以降の
      // フェンス内が丸ごと誤検出になる。
      expect(scanWarningHeadings('```\n~~~\n# ⚠ まだフェンスの中\n```'), isEmpty);
      // フェンスを閉じたあとは見る。
      expect(scanWarningHeadings('```\ncode\n```\n\n# ⚠ だめ'), hasLength(1));
      // リストの中の字下げされたフェンスも飛ばす。
      expect(
        scanWarningHeadings('- 例:\n\n  ```sh\n  # ⚠ コメント\n  ```'),
        isEmpty,
      );
    });

    test('サイズ: 当てるべき形', () {
      // 閾値超過（budget が無い）。
      expect(
        scanSizeViolations(
          sizes: {'a.md': 60001},
          budgets: const {},
          threshold: 60000,
        ),
        hasLength(1),
      );
      // budget 超過。
      expect(
        scanSizeViolations(
          sizes: {'a.md': 70001},
          budgets: const {'a.md': 70000},
          threshold: 60000,
        ),
        hasLength(1),
      );
      // ⚠⚠ stale な exemption —— 閾値を下回ったのに budget が残っている。
      expect(
        scanSizeViolations(
          sizes: {'a.md': 50000},
          budgets: const {'a.md': 59999},
          threshold: 60000,
        ),
        hasLength(1),
      );
      // ⚠ budget が実測から離れすぎ（ラチェットが締まっていない）。
      expect(
        scanSizeViolations(
          sizes: {'a.md': 70000},
          budgets: const {'a.md': 90001},
          threshold: 60000,
        ),
        hasLength(1),
      );
      // exemption の相手が消えた。
      expect(
        scanSizeViolations(
          sizes: const {},
          budgets: const {'消えた.md': 90000},
          threshold: 60000,
        ),
        hasLength(1),
      );
    });

    test('サイズ: 当ててはいけない形', () {
      // 閾値の内側。
      expect(
        scanSizeViolations(
          sizes: {'a.md': 60000},
          budgets: const {},
          threshold: 60000,
        ),
        isEmpty,
      );
      // budget の内側で、実測との差も許容幅に収まっている。
      expect(
        scanSizeViolations(
          sizes: {'a.md': 80000},
          budgets: const {'a.md': 90000},
          threshold: 60000,
        ),
        isEmpty,
      );
      // ぴったり budget。
      expect(
        scanSizeViolations(
          sizes: {'a.md': 90000},
          budgets: const {'a.md': 90000},
          threshold: 60000,
        ),
        isEmpty,
      );
    });
  });

  // ⚠⚠ **これが本体の空振り検査。**読み込み → フェンス判定 → 抽出の全段を通して
  // 「直す前の綴りへ戻せば落ちる」ことを見る。
  group('⚠ 歯があることを、実際に穴を開けて確かめる', () {
    test('実ファイルを直す前の綴りへ戻すと検出できる', () {
      // #1184 で直した実物の綴り。⚠ **合成ソースではなく、実際にあった形**
      // （2 の合成テストは自分が想定した書き方しか並べない・#1062 の反省）。
      const before = [
        '## ⚠⚠ Xcode の版は pin していない（Flutter と違って勝手に動く）',
        '### ⚠ 層③ の測り方（2026-08-31 に誤診しかけた）',
        '#### ⚠⚠ 2026-09-12: 実際に閾値を超え、**順序 1 だけ逃がした**',
        // ⚠ 先頭が ⚠ で、かつ**途中にも** ⚠⚠ がある形。片方だけ見ていると
        // 当たり方を間違える。
        '##### ⚠ 2026-09-28 の調査 —— 制約の実体（⚠⚠ **方針の追加・変更は無い**）',
      ];
      final file = File('$docsDir/dev-environment.md');
      final fixed = file.readAsStringSync();
      expect(scanWarningHeadings(fixed), isEmpty, reason: '直したあとは緑');

      final hole = '$fixed\n\n${before.join('\n\n')}\n';
      expect(scanWarningHeadings(hole), hasLength(before.length));
      // ⚠ フェンス内の実物を抱えたまま増えていること —— 誤検出で数が水増しに
      // なっていない。
      expect(scanWarningHeadings(hole).map((v) => v.text), containsAll(before));
    });

    test('実測のサイズを budget 超過へ振ると落ちる', () {
      final sizes = {
        for (final f in sizeScanFiles) f.uri.pathSegments.last: f.lengthSync(),
      };
      expect(
        scanSizeViolations(
          sizes: sizes,
          budgets: _budgets,
          threshold: _threshold,
        ),
        isEmpty,
        reason: '直したあとは緑',
      );
      // 4 件の exemption すべてが、1 バイト増えれば落ちる状態にあること。
      for (final name in _budgets.keys) {
        expect(
          scanSizeViolations(
            sizes: {...sizes, name: _budgets[name]! + 1},
            budgets: _budgets,
            threshold: _threshold,
          ),
          hasLength(1),
          reason: '⚠⚠ $name の budget が実測より緩い。足したぶんが黙って通る',
        );
      }
      // budget を持たないファイルが閾値を超えたら落ちること。
      final plain = sizeScanFiles
          .map((f) => f.uri.pathSegments.last)
          .firstWhere((n) => !_budgets.containsKey(n));
      expect(
        scanSizeViolations(
          sizes: {...sizes, plain: _threshold + 1},
          budgets: _budgets,
          threshold: _threshold,
        ),
        hasLength(1),
      );
    });
  });
}

/// 1 回の Read（25,000 トークン）に収まる上限。
///
/// ⚠⚠ **実測から来ている値。**このリポジトリの docs は約 2.55 バイト/トークンで、
/// 64,720 バイトが 25,383 トークンだった（2026-09-30）。63.7KB が実際の限界で、
/// ここはそこへ余裕を持たせた値。⚠ **上げないこと。**上げるなら、その版の Read の
/// 上限とバイト/トークンを**測り直して**doc に残す。
const _threshold = 60000;

/// 閾値を超えたまま残っている 4 件（2026-09-30 実測・`docs/` 直下からの相対名）。
///
/// ⚠⚠ **この表の数字は下げるだけ。**足すなら同じ回で同じだけ削る。
/// ⚠ 閾値を下回ったら**行を消す**（[scanSizeViolations] が stale として落とす）。
/// ⚠ 実測から 10,000 バイト以上離れたら、実測へ下げる（ラチェットを締める）。
///
/// 直し方の既定は **落ち着いた節を `docs/archive/` へ移す**（#1184 の案 A）。
/// ⚠ **節番号は振り直さない** —— コードのコメントが節を名前で参照している。
const _budgets = <String, int>{
  'dev-environment.md': 91127,
  'tech-notes.md': 86271,
  'CLAUDE.md': 84859,
  'paid-relay-plan.md': 76463,
};

/// budget が実測からこれ以上離れていたら、下げるよう促す。
const _budgetSlack = 10000;

/// 見出し行 1 件。
typedef WarningHeading = ({int line, String text});

/// 先頭が `⚠` の見出しを拾う。
///
/// ⚠⚠ **フェンスの中は見出しではない。**シェルのコメント（`# ⚠ …`）が実在する
/// ので、素朴な行頭マッチは誤検出する。開いた記号（``` / ~~~）と同じ記号でしか
/// 閉じないようにしてあるのは、**閉じたと誤認すると以降が丸ごと誤検出になる**ため。
List<WarningHeading> scanWarningHeadings(String markdown) {
  final out = <WarningHeading>[];
  final lines = markdown.split('\n');
  String? fence;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final opener = _fenceOpener.firstMatch(line.trimLeft())?.group(1);
    if (opener != null) {
      // ⚠ 開いたときと同じ記号で、同じ長さ以上でなければ閉じない。閉じたと
      // 誤認すると、以降のフェンス内が丸ごと誤検出になる。
      if (fence == null) {
        fence = opener;
      } else if (opener[0] == fence[0] && opener.length >= fence.length) {
        fence = null;
      }
      continue;
    }
    if (fence != null) continue;
    if (_warningHeading.hasMatch(line)) {
      out.add((line: i + 1, text: line));
    }
  }
  return out;
}

/// 見出しの総数（違反かどうかに関係なく）。走査が空振りしていないかを見るため。
int _countHeadings(String markdown) {
  var count = 0;
  final lines = markdown.split('\n');
  String? fence;
  for (final line in lines) {
    final trimmed = line.trimLeft();
    final opener = _fenceOpener.firstMatch(trimmed)?.group(1);
    if (opener != null) {
      if (fence == null) {
        fence = opener;
      } else if (opener[0] == fence[0] && opener.length >= fence.length) {
        fence = null;
      }
      continue;
    }
    if (fence != null) continue;
    if (_anyHeading.hasMatch(line)) count++;
  }
  return count;
}

final _fenceOpener = RegExp(r'^(`{3,}|~{3,})');

/// ⚠ `#` は 1〜6 個。7 個以上は Markdown の見出しではない。
final _warningHeading = RegExp(r'^#{1,6}[ \t]+⚠');
final _anyHeading = RegExp(r'^#{1,6}[ \t]+\S');

/// サイズのラチェット。違反の説明を返す（空なら合格）。
///
/// ⚠⚠ **exemption を「増やしてよい枠」にしないための検査が 3 本入っている** ——
/// 実測が budget を超えたら落ち、budget が閾値を下回ったら（＝もう要らないのに
/// 残っていたら）落ち、budget が実測から離れすぎたら落ちる。
/// ⚠ **この 3 本目が無いと、budget は一度書いたら二度と締まらない。**
List<String> scanSizeViolations({
  required Map<String, int> sizes,
  required Map<String, int> budgets,
  required int threshold,
  int slack = _budgetSlack,
}) {
  final out = <String>[];
  for (final entry in sizes.entries) {
    final budget = budgets[entry.key];
    if (budget == null) {
      if (entry.value > threshold) {
        out.add(
          '${entry.key}: ${entry.value} バイトで閾値 $threshold を超えた。'
          '落ち着いた節を docs/archive/ へ移す（節番号は振り直さない）',
        );
      }
      continue;
    }
    if (entry.value > budget) {
      out.add(
        '${entry.key}: ${entry.value} バイトで記録済み budget $budget を超えた。'
        '⚠ budget は下げるだけ。足すなら同じ回で同じだけ削る',
      );
    }
  }
  for (final entry in budgets.entries) {
    final size = sizes[entry.key];
    if (size == null) {
      out.add('${entry.key}: exemption が残っているがファイルが無い。行を消す');
      continue;
    }
    if (entry.value <= threshold) {
      out.add(
        '${entry.key}: budget ${entry.value} が閾値 $threshold を下回っている。'
        '⚠ 役目を終えた exemption なので行を消す',
      );
      continue;
    }
    if (entry.value - size > slack) {
      out.add(
        '${entry.key}: budget ${entry.value} が実測 $size から $slack バイト以上'
        '離れている。⚠ 実測へ下げてラチェットを締める',
      );
    }
  }
  out.sort();
  return out;
}

List<File> _markdownFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.md'))
    .toList();

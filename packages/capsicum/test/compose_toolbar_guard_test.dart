import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1167: 投稿画面の下のツールバーが、横スクロールへ戻らないこと。
///
/// ⚠⚠ **横スクロールは「届かない場所」を作る。**デスクトップはホイールが縦にしか
/// 回らず、ドラッグでもスクロールしないので、はみ出た分は実質的に操作できない。
/// しかも**はみ出していたのは公開範囲とローカル限定**——送る前に確かめたいものだった
/// （2026-09-20 の要望・Windows 630px のスクリーンショット）。
///
/// ⚠ 2026-09-26 pooza の決定（案 3+2）: **アイコン列は幅に応じて「…」へ畳み、
/// 送信時の設定は別の行へ出して常に見える**ようにする。⚠ **この 2 つが崩れると
/// 元の不具合に戻る**ので機械で見る。
void main() {
  const path = 'lib/src/ui/screen/compose_screen.dart';

  String read() => File(path).readAsStringSync();

  /// [head] に一致するメソッドの本体を、括弧の対応で切り出す。
  ///
  /// ⚠⚠ **「次に出てくるインデント 2 の `}`」で切らない** (#1167・案 B)。
  /// 以前の `toolbarRegion` は `OverflowIconRow(actions:` の出現位置から
  /// `\n  }` までを領域としていたが、案 B で `_buildToolbar` へ切り出したところ
  /// **送信時の設定がその範囲の手前（ローカル関数の定義）へ移り、領域から外れた**。
  /// 検査は「設定がツールバーの領域に実在する」ことを見ているので、
  /// **領域の取り方が変わると意味ごと失われる**。メソッド単位で掴めばずれない。
  String methodBody(String source, RegExp head) {
    final m = head.firstMatch(source);
    expect(m, isNotNull, reason: '$head が見つからない。変えたならこの検査も直す');
    var depth = 0;
    String? quote;
    for (var i = m!.end - 1; i < source.length; i++) {
      final c = source[i];
      if (quote != null) {
        if (c == r'\') {
          i++;
        } else if (c == quote) {
          quote = null;
        }
        continue;
      }
      if (c == "'" || c == '"') {
        quote = c;
        continue;
      }
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return source.substring(m.end, i);
      }
    }
    fail('$head の終端が見つからない');
  }

  /// `_toolbarActions` の本体（＝**畳まれる側**）。
  String actionsBody(String source) => methodBody(
    source,
    RegExp(r'List<OverflowIconAction> _toolbarActions\([^)]*\) \{'),
  );

  /// ツールバーを組んでいるところ（`_buildToolbar` の本体）。
  String toolbarRegion(String source) =>
      methodBody(source, RegExp(r'Widget _buildToolbar\([^)]*\) \{'));

  /// 送信時の設定が「畳まれる側」に混ざっていないか。
  ///
  /// ⚠ 混ざると狭い幅で「…」の中へ入り、**送る前に確かめられなくなる**。
  const sendTimeSettings = ['PostScope', 'ローカルのみ', '引用許可'];

  List<String> settingsInActions(String source) {
    final body = maskComments(actionsBody(source));
    return [
      for (final needle in sendTimeSettings)
        if (body.contains(needle)) needle,
    ];
  }

  group('⚠ 走査が空振りしていない', () {
    test('前提: _toolbarActions の本体を実際に切り出せている', () {
      final body = actionsBody(maskComments(read()));

      expect(body.trim(), isNotEmpty);
      // 代表的なアイコンが実在すること（減ったらパターンが実物から外れている）。
      expect(body, contains("key: 'media'"));
      expect(body, contains("key: 'emoji'"));
      expect(body, contains("key: 'cw'"));
      expect(
        RegExp('OverflowIconAction\\(').allMatches(body).length,
        greaterThanOrEqualTo(8),
      );
    });

    test('前提: 送信時の設定はツールバーの領域に実在する', () {
      final region = maskComments(toolbarRegion(read()));

      for (final needle in sendTimeSettings) {
        expect(region, contains(needle), reason: needle);
      }
    });

    test('前提: 領域は `_buildToolbar` 1 本ぶんで、ファイル全体ではない', () {
      final source = read();
      final region = toolbarRegion(source);

      // ⚠ 上下の両端を持っていること（2 段側と 1 段側の両方が入る）。
      expect(region, contains('OverflowIconRow(actions:'));
      expect(region, contains('LayoutBuilder('));
      // ⚠⚠ **括弧の対応が壊れてファイルを丸ごと掴んでいないこと。**丸ごとだと
      // 「設定が領域にある」は常に真になり、検査が何も見ていない状態になる。
      expect(region.length, lessThan(source.length ~/ 3));
      expect(region, isNot(contains('Widget build(BuildContext context) {')));
    });

    test('前提: 畳まれる側と領域は別物（同じものを 2 回見ていない）', () {
      final source = read();
      // ⚠ `_toolbarActions` は `_buildToolbar` の外にあるので、領域に本体は
      // 含まれない（呼び出しだけが入る）。ここが崩れると「混ざっていない」の
      // 判定が自明に真になる。
      expect(toolbarRegion(source), isNot(contains("key: 'media'")));
      expect(actionsBody(source), contains("key: 'media'"));
    });
  });

  group('⚠ 判定に合成ソースを食わせる', () {
    test('分かれている合成ソースは通る', () {
      expect(settingsInActions(_synthetic()), isEmpty);
    });

    test('⚠⚠ 公開範囲を畳まれる側へ混ぜたら検出する', () {
      expect(settingsInActions(_synthetic(leakScope: true)), ['PostScope']);
    });

    test('⚠ コメントでの言及は数えない', () {
      expect(
        settingsInActions(
          _synthetic(extraComment: '      // PostScope はここに入れない（ローカルのみ も）'),
        ),
        isEmpty,
      );
    });
  });

  group('⚠⚠ 歯があることを、穴を開けて確かめる', () {
    test('#1167 の前（`dab8e314`）は横スクロールで、公開範囲が同じ行にあった', () {
      final before = Process.runSync('git', [
        'show',
        'dab8e314:packages/capsicum/$path',
      ], workingDirectory: '../..');
      expect(before.exitCode, 0, reason: (before.stderr as String));
      final source = maskComments(before.stdout as String);

      // ⚠ そもそも `_toolbarActions` も `OverflowIconRow` も無かった。
      expect(source, isNot(contains('_toolbarActions')));
      expect(source, isNot(contains('OverflowIconRow')));
      // 公開範囲が横スクロールの Row の中にあった（同じ行に並んでいた証拠）。
      final scroll = source.indexOf('scrollDirection: Axis.horizontal');
      final scope = source.indexOf('DropdownButton<PostScope>');
      expect(scroll, greaterThan(0));
      expect(scope, greaterThan(scroll));
    });
  });

  test('⚠⚠ 送信時の設定は畳まれる側に混ざっていない', () {
    final leaked = settingsInActions(read());
    if (leaked.isNotEmpty) {
      fail(
        '送信時の設定が `_toolbarActions`（畳まれる側）に混ざっている: '
        '${leaked.join(' / ')}\n'
        '⚠ 狭い幅で「…」の中へ入り、送る前に確かめられなくなる (#1167)。'
        '公開範囲・ローカル限定・引用許可は下の `Wrap` の行へ置くこと。',
      );
    }
  });

  test('⚠⚠ ツールバー自身が横スクロールを組み立てていない', () {
    final region = maskComments(toolbarRegion(read()));

    // ⚠⚠ **2026-09-30 に禁止から条件付き許可へ変えた。**#1167 が横スクロールを
    // 捨てたのは「気付けない・マウスで操作できない」からで、**機構そのものが
    // 悪かったのではない**。畳む形を 13 mini へ当てたら**アイコンが 1 つも
    // 出なくなった**ので、届く形（常時スクロールバー + マウスドラッグ）にして
    // 戻した。⚠ **ただし組み立てるのはここではない** —— 生の
    // `SingleChildScrollView` を置くと、送信時の設定を中に入れてしまえる。
    expect(
      region,
      isNot(contains('scrollDirection: Axis.horizontal')),
      reason:
          '⚠⚠ ツールバーで直に横スクロールを組まないこと。`ScrollingIconRow` へ委ねる —— '
          'あちらは `List<OverflowIconAction>` しか受け取らないので、'
          '**送信時の設定が型として中に入らない**（元の不具合の再発を構造で止める）',
    );
    expect(
      region,
      contains('ScrollingIconRow('),
      reason: '⚠ 狭い幅は流す形。畳む形は残り幅が小さいと 0 個になる',
    );
    expect(region, contains('Wrap('), reason: '⚠ 送信時の設定は折り返す（切れて届かなくならないように）');
  });

  group('⚠ 案 B の形が崩れていない (#1167・2026-09-28 pooza 決定)', () {
    test('幅で 2 つの形を使い分けている', () {
      final region = maskComments(toolbarRegion(read()));

      // ⚠ 境目は定数で持つ（リテラルを直に書くと、意味と値の対応が失われる）。
      expect(
        region,
        contains('kComposeToolbarTwoRowMinWidth'),
        reason: '⚠ 幅の境目が消えている。狭い幅で 3 段に戻る',
      );
      expect(
        region,
        contains('kComposeToolbarMinIconRowWidth'),
        reason:
            '⚠⚠ 「…」1 個ぶんの確保が消えている。設定が伸びきると、'
            '**畳まれたアイコンを開く手段が無くなる**',
      );
    });

    test('⚠⚠ 2 つの形は同じ builder から作る（片方だけ古くならない）', () {
      final region = maskComments(toolbarRegion(read()));

      // ⚠⚠ **設定の組み立てを 2 か所に書かないこと。**書くと、次に設定を 1 つ
      // 足した人が片方だけ直し、**広い幅では出るのに狭い幅では出ない**（またはその逆）
      // という「見えないまま効いている」を作る —— #1167 の元の不具合と同型。
      final calls = RegExp(r'settings\(compact:').allMatches(region).length;
      expect(
        calls,
        2,
        reason:
            '⚠ 2 段側と 1 段側で `settings(compact: …)` を 1 回ずつ呼ぶ形を保つこと。'
            '2 か所に組み立てを写したら、この検査を消すのではなく形を戻す',
      );
      // 定義は 1 つだけ。
      expect(
        RegExp(
          r'List<Widget> settings\(\{required bool compact\}\)',
        ).allMatches(region).length,
        1,
      );
    });

    test('⚠ 詰めるのは閉じているボタンだけ（選択肢はフルラベル）', () {
      final region = maskComments(toolbarRegion(read()));

      // 閉じている側は詰めた文字、メニューはフルラベル。⚠ **`items` 側まで詰めると
      // 選ぶときに正式な名前が見えなくなる。**
      expect(
        region,
        contains('compactSettingLabel(postScopeLabel(_scope, adapter))'),
        reason: '⚠ 閉じている側は詰める',
      );
      expect(
        region,
        contains('label: postScopeLabel(scope, adapter)'),
        reason: '⚠⚠ メニューの選択肢はフルラベル（`compactSettingLabel` を通さない）',
      );
    });

    test('⚠⚠ 詰めた側で DropdownButton を使っていない', () {
      final region = maskComments(toolbarRegion(read()));

      // ⚠⚠ **`DropdownButton` は選択肢を `IndexedStack` に積むので、いちばん長い
      // 選択肢ぶんの幅を常に確保する**（`dropdown.dart` の `innerItemsWidget`）。
      // 13 mini では「公開」を選んでいても「非公開の…」ぶんの幅を取り続け、
      // **設定だけで 375pt 中 300pt を占めてアイコンが 1 つも出なかった**
      // （2026-09-30 実測）。⚠⚠ **表示文字を詰めても幅は詰まらない** ——
      // 検査が文字列の規則だけを見ていたので、ここを捕まえられなかった。
      expect(
        region,
        contains('_compactMenu<'),
        reason: '⚠ 詰めた側は `PopupMenuButton`（閉じている子の幅しか取らない）',
      );
      // 詰めた側の枝（`if (compact)` の直後）に DropdownButton が無いこと。
      final branches = _compactBranches(region);
      // ⚠ 走査が空振りしていないこと。枝が取れていないと下のループは 0 回で、
      // 検査が何も見ていない状態になる（公開範囲 / 言語 / 引用許可 / ローカルのみ）。
      expect(branches, hasLength(4), reason: '⚠⚠ 詰めた側の枝は 4 つ');
      for (final branch in branches) {
        expect(
          branch,
          isNot(contains('DropdownButton')),
          reason:
              '⚠⚠ 詰めた側に `DropdownButton` がある。現在値が短くても'
              '**最長の選択肢ぶんの幅**を取るので、いちばん狭いところで'
              'アイコンが 0 個になる',
        );
      }
      // ⚠ 歯の確認: 枝へ `DropdownButton` を差し込むと落ちること。
      final hole = _compactBranches(
        region.replaceFirst('_compactMenu<', 'DropdownButton<'),
      );
      expect(hole.any((b) => b.contains('DropdownButton')), isTrue);
    });
  });
}

/// `if (compact)` 〜 対応する `else` までの本文（＝**詰めた側の枝**）。
///
/// ⚠ **同じインデントの `else` で閉じる。**ネストした `if` の `else` を拾うと
/// 枝が途中で切れ、`DropdownButton` を見落とす。
List<String> _compactBranches(String region) {
  final branches = <String>[];
  for (final m in RegExp(r'(?<indent>[ ]*)if \(compact\)').allMatches(region)) {
    final indent = m.namedGroup('indent')!;
    final close = region.indexOf(
      '\n$indent'
      'else',
      m.end,
    );
    branches.add(
      close < 0 ? region.substring(m.end) : region.substring(m.end, close),
    );
  }
  return branches;
}

/// 判定に食わせる合成ソース。
String _synthetic({bool leakScope = false, String? extraComment}) =>
    '''
class _State {
  List<OverflowIconAction> _toolbarActions(BuildContext context) {
${extraComment ?? ''}
    return [
      OverflowIconAction(key: 'media', icon: i, tooltip: 'メディアを添付', onPressed: f),
      OverflowIconAction(key: 'emoji', icon: i, tooltip: '絵文字', onPressed: f),
${leakScope ? "      DropdownButton<PostScope>(value: _scope)," : ''}
    ];
  }

  Widget build(BuildContext context) {
    return Column(
      children: [
        OverflowIconRow(actions: _toolbarActions(context)),
        Wrap(
          children: [
            DropdownButton<PostScope>(value: _scope),
            FilterChip(label: const Text('ローカルのみ')),
          ],
        ),
      ],
    );
  }
}
''';

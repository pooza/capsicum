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

  /// `_toolbarActions` の本体を切り出す。
  String actionsBody(String source) {
    final head = RegExp(
      r'List<OverflowIconAction> _toolbarActions\([^)]*\) \{',
    );
    final m = head.firstMatch(source);
    expect(m, isNotNull, reason: '_toolbarActions が見つからない。変えたならこの検査も直す');
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
    fail('_toolbarActions の終端が見つからない');
  }

  /// ツールバーを組んでいるところ（`OverflowIconRow` から build の終わりまで）。
  String toolbarRegion(String source) {
    final start = source.indexOf('OverflowIconRow(actions:');
    expect(start, greaterThan(0), reason: 'OverflowIconRow を使っていない');
    // build メソッドの終わり（インデント 2 の `}`）で切る。
    final end = source.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    return source.substring(start, end);
  }

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

  test('⚠⚠ ツールバーの領域に横スクロールを戻していない', () {
    final region = maskComments(toolbarRegion(read()));

    expect(
      region,
      isNot(contains('scrollDirection: Axis.horizontal')),
      reason: '⚠⚠ 横スクロールは「届かない場所」を作る。畳むか折り返すかにすること',
    );
    expect(region, contains('Wrap('), reason: '⚠ 送信時の設定は折り返す（切れて届かなくならないように）');
  });
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

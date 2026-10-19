import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// #1304: Sentry へ送りたい値を `Hint` に載せない。
///
/// ⚠⚠ **`Hint` はプロセス内だけのデータで、イベントとしては送られない。**
/// 続き読みの失敗の `site`（`notification.loadMore` / ハッシュタグ・リスト・
/// チャンネルの続き読み）を `hint: Hint.withMap({...})` で渡していたので、
/// Sentry ではどの続き読みの失敗かを見分けられなかった。送りたい値は
/// `withScope` の `setTag` / `setContexts` に載せる。
///
/// ⚠ 対象外は [allowlist]（hint も渡しているが、送りたい値は scope に載せて
/// あるもの）。
void main() {
  final sources = sourceFiles('lib');

  const allowlist = <String, String>{
    'lib/src/util/conversion_skip_report.dart':
        'hint は beforeSend 内の照合用。送りたい件数と発生元は withScope に載せてある',
  };

  final pattern = RegExp(r'\bhint:\s*Hint\.');

  int hitsIn(String source) => pattern.allMatches(maskComments(source)).length;

  group('⚠ 走査が空振りしていない', () {
    test('lib の走査が実際にファイルを拾っている', () {
      expect(sources.length, greaterThan(100));
    });

    test('対象外の指定は実在し、実際に当たるものだけ', () {
      for (final path in allowlist.keys) {
        expect(
          hitsIn(File(path).readAsStringSync()),
          greaterThan(0),
          reason: path,
        );
      }
    });
  });

  test('⚠ 判定に合成ソースを食わせる', () {
    expect(hitsIn("captureException(e, hint: Hint.withMap({'a': 1}));"), 1);
    expect(hitsIn("captureException(e,\n  hint: Hint.withMap({}),\n);"), 1);
    // 入力欄の hint（ウィジェット）とコメントは当てない。
    expect(hitsIn("InputDecoration(hint: Text('x'))"), 0);
    expect(hitsIn('// hint: Hint.withMap は使わない'), 0);
  });

  test('⚠⚠ 修正前の timeline_provider は当たる', () {
    // `b5d6147f` = #1304 の修正の前。続き読みの 2 か所が hint だった。
    final before = Process.runSync('git', [
      'show',
      'b5d6147f:packages/capsicum/lib/src/provider/timeline_provider.dart',
    ], workingDirectory: '../..');
    expect(before.exitCode, 0, reason: (before.stderr as String));
    expect(hitsIn(before.stdout as String), 2);
  });

  test('送りたい値を Hint に載せていない', () {
    final offenders = [
      for (final file in sources)
        if (!allowlist.containsKey(file.path) &&
            hitsIn(file.readAsStringSync()) > 0)
          file.path,
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          'Hint はイベントとして送られない。送りたい値は withScope の setTag / '
          'setContexts に載せること (#1304)',
    );
  });
}

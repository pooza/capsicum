import 'dart:io';

import 'package:capsicum/src/constants.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1027-D: Sentry の `phase` タグの綴りを 1 箇所に保つ。
///
/// ⚠⚠ **部分的な集約がいちばん悪い。**[ReactionPhase] は #976 で作られたが、
/// 入っていたのは `reaction_add` / `reaction_remove` の 2 つだけで、
/// **`'post_action'` は 7 箇所へ直書きのまま**だった（`post_tile` ×3 /
/// `cross_account_boost` / `post_actions` ×3）。定数が「ある」ように見えるので、
/// 次に足す人は直書き側を真似する。
///
/// タグ名を直すと Sentry 上で新旧が混在して母数が割れるため、綴りが散ることの
/// コストは書き換えの手間では済まない。
void main() {
  const root = 'lib';

  /// 直書きしてはいけない値と、代わりに使う定数の名前。
  const phases = <({String literal, String constant})>[
    (literal: 'post_action', constant: 'ReactionPhase.post'),
    (literal: 'reaction_add', constant: 'ReactionPhase.add'),
    (literal: 'reaction_remove', constant: 'ReactionPhase.remove'),
  ];

  /// 綴りを持ってよい唯一の場所。
  const declarationFile = 'lib/src/constants.dart';

  List<File> dartFiles() => Directory(root)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => !f.path.endsWith('.g.dart'))
      .toList();

  /// 行コメントを落とす。doc で値に言及しただけの行を違反にしない。
  String stripLineComments(String source) => source
      .split('\n')
      .map((line) {
        final i = line.indexOf('//');
        return i == -1 ? line : line.substring(0, i);
      })
      .join('\n');

  test('探索そのものが壊れていない', () {
    expect(dartFiles().length, greaterThan(50));
    expect(File(declarationFile).existsSync(), isTrue);
  });

  test('定数と実際の綴りが一致している', () {
    // ⚠ 検査が古い綴りを守り続けないよう、実物と突き合わせる。
    expect(ReactionPhase.post, 'post_action');
    expect(ReactionPhase.add, 'reaction_add');
    expect(ReactionPhase.remove, 'reaction_remove');
  });

  test('phase の綴りを直書きしない (#1027-D)', () {
    final offenders = <String>[];
    for (final file in dartFiles()) {
      final path = file.path;
      if (path == declarationFile) continue;
      final source = stripLineComments(file.readAsStringSync());
      for (final phase in phases) {
        if (!source.contains("'${phase.literal}'")) continue;
        offenders.add('$path: \'${phase.literal}\' → ${phase.constant}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'phase タグの綴りは constants.dart の ReactionPhase だけが持つ。'
          'タグ名を直すと Sentry 上で新旧が混在して母数が割れる'
          '\n${offenders.join('\n')}',
    );
  });
}

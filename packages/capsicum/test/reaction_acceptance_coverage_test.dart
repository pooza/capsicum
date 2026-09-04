import 'dart:io';

import 'package:capsicum/src/ui/util/reaction_acceptance.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1044 の経路網羅検査（リリース PR の Codex P1 で追加）。
///
/// ⚠⚠ **判定をピッカーの入口にだけ置いて 4 経路を取りこぼした。**既存の
/// リアクションチップのタップ・カスタム絵文字のタップ・通知タイルのピッカーは
/// 素通しで、そこではサーバーが黙って ❤️ へ差し替える**元の実害がそのまま
/// 残っていた**。
///
/// ⚠ **#990 が「片方だけに入れて 6 経路を取りこぼした」形と同じ。**それを
/// 警戒すると commit message に書いた回に、同じことをしていた。**人手の
/// 「全部見たつもり」は当てにならないので機械で止める。**
void main() {
  const files = [
    'lib/src/ui/widget/post_tile.dart',
    'lib/src/ui/widget/post_touch_action_row.dart',
    'lib/src/ui/widget/notification_tile.dart',
  ];

  test('addReaction を呼ぶ行はすべて受付条件の判定を通している', () {
    final offenders = <String>[];

    for (final path in files) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('addReaction(')) continue;
        // 呼び出しは複数行に折り返されるので、後続数行まで見る。
        final window = lines
            .sublist(i, (i + 8).clamp(0, lines.length))
            .join('\n');
        final guarded =
            window.contains('effectiveReaction(') ||
            window.contains('kMisskeyReactionFallback');
        if (!guarded) offenders.add('$path:${i + 1}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          '受付条件を見ずに addReaction を呼んでいる経路がある (#1044)。'
          'Misskey は受け付けられないリアクションをエラーにせず ❤️ へ差し替えるので、'
          '**成功扱いのまま違う絵文字が付く**。'
          'effectiveReaction() を通すか、likeOnly 判定で fallback を直接送ること',
    );
  });

  test('effectiveReaction は likeOnly で fallback へ倒す', () {
    final post = Post(
      id: '1',
      postedAt: DateTime.utc(2026),
      author: User(id: 'u1', username: 'someone', host: 'example.com'),
      reactionAcceptance: ReactionAcceptance.likeOnly,
    );

    expect(
      effectiveReaction(':party_parrot:', post, myHost: 'example.com'),
      kMisskeyReactionFallback,
    );
  });

  test('effectiveReaction は制限が無ければそのまま返す', () {
    final post = Post(
      id: '1',
      postedAt: DateTime.utc(2026),
      author: User(id: 'u1', username: 'someone', host: 'example.com'),
    );

    expect(
      effectiveReaction(':party_parrot:', post, myHost: 'example.com'),
      ':party_parrot:',
    );
  });
}

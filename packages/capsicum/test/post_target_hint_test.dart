import 'dart:io';

import 'package:capsicum/src/ui/widget/server_badge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// 入力欄のヒントに、どのサーバーへ投稿するかを出す。簡易投稿バー (#1313) と
/// 投稿画面 (#1328) が同じものを使う。
void main() {
  test('サーバーを先に置く（狭い幅で後ろが切れても残る）', () {
    // サーバー名がまだ取れていないときはホスト名。
    expect(
      postTargetHint(postLabel: '投稿', host: 'mstdn.example'),
      'mstdn.exampleに投稿...',
    );
  });

  test('投稿ラベルはサーバーの呼び方に従う（Misskey のノートなど）', () {
    expect(
      postTargetHint(postLabel: 'ノート', host: 'misskey.example'),
      'misskey.exampleにノート...',
    );
  });

  test('アカウントが無いときは従来どおり', () {
    expect(postTargetHint(postLabel: '投稿', host: null), '投稿...');
  });

  // ⚠ 集約したものは「使っていること」まで見る（docs/CLAUDE.md「ソース検査
  // ガードの書き方」）。投稿画面が「今なにしてる？」に戻ると、ヒントの関数は
  // 緑のまま、取り違えの手当てだけが黙って消える。
  group('両方の入力欄が postTargetHint を使っている', () {
    const files = {
      '簡易投稿バー (#1313)': 'lib/src/ui/widget/simple_post_bar.dart',
      '投稿画面 (#1328)': 'lib/src/ui/screen/compose_screen.dart',
    };
    for (final MapEntry(key: name, value: path) in files.entries) {
      test(name, () {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: '走査の対象が無い（$path）');
        expect(postTargetHintProblems(file.readAsStringSync()), isEmpty);
      });
    }
  });

  group('判定（合成ソース）', () {
    test('hintText: postTargetHint( は問題なし', () {
      expect(
        postTargetHintProblems(
          "decoration: InputDecoration(hintText: postTargetHint(postLabel: l, host: h)),",
        ),
        isEmpty,
      );
    });

    test('⚠⚠ #1328: 「今なにしてる？」に戻ると落ちる', () {
      expect(
        postTargetHintProblems(
          "decoration: const InputDecoration(hintText: '今なにしてる？'),",
        ),
        isNotEmpty,
      );
    });

    test('コメントの中にしか無ければ落ちる', () {
      expect(
        postTargetHintProblems(
          "// hintText: postTargetHint(\ndecoration: InputDecoration(hintText: 'x'),",
        ),
        isNotEmpty,
      );
    });
  });
}

/// 問題を列挙する（空なら問題なし）。
List<String> postTargetHintProblems(String dart) {
  final src = maskComments(dart);
  return [
    if (!RegExp(r'hintText:\s*postTargetHint\(').hasMatch(src))
      'hintText に postTargetHint を使っていない（どのサーバーへ投稿するかが出ない）',
  ];
}

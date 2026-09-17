import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1148: 投稿・プロフィール・ハッシュタグは `openPost` / `openProfile` /
/// `openHashtag`（`deck_navigation.dart`）で開く。
///
/// ⚠⚠ **素の `context.push('/post' …)` は、デッキのカラムの中から開いても全画面へ
/// 遷移し、ルートのスコープ（現在のアカウント）で動く。**カラム B の投稿 id を
/// アカウント A のアダプタで引くことになり、別の投稿・別のユーザーを指しうる
/// （id はサーバーローカル）。
///
/// ⚠ 対象外: `router.dart`（ルート定義）と `deck_navigation.dart`（振り分けの本体）。
void main() {
  final libDir = Directory('lib');
  final sources = libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  const allowlist = [
    'lib/src/router.dart',
    'lib/src/ui/util/deck_navigation.dart',
  ];

  // ⚠ `/profile/edit` は対象外（自分のプロフィール編集はカラムにならない）なので、
  // `/profile` は閉じ引用符まで含めて照合する。`/hashtag/` は `$tag` が続く。
  // ⚠ 型引数は入れ子になりうる（`push<List<Attachment>>(`）。
  final pattern = RegExp(
    r'''\b(?:push|go|pushReplacement|replace)(?:<[^(]*>)?\(\s*['"]/(?:post['"]|profile['"]|hashtag/)''',
  );

  List<String> offendersIn(String source) {
    final masked = maskComments(source);
    return [
      for (final match in pattern.allMatches(masked))
        masked
            .substring(match.start, (match.end + 40).clamp(0, masked.length))
            .replaceAll(RegExp(r'\s+'), ' '),
    ];
  }

  group('⚠ 走査が空振りしていない', () {
    test('lib の走査が実際にファイルを拾っている', () {
      expect(sources.length, greaterThan(100));
    });

    test('振り分けの本体（deck_navigation.dart）は実際に当たる', () {
      // ⚠ これが当たらなくなったら、パターンが実物の書き方から外れている。
      final helper = File(
        'lib/src/ui/util/deck_navigation.dart',
      ).readAsStringSync();
      expect(offendersIn(helper), hasLength(3));
    });
  });

  group('⚠ 判定に合成ソースを食わせる', () {
    test('素の遷移は当たる', () {
      const samples = [
        "context.push('/post', extra: post);",
        "context.push(\n  '/profile',\n  extra: post.author,\n);",
        "context.push('/hashtag/\$tag');",
        "context.push('/hashtag/\${tag.name}');",
        'context.go("/post", extra: post);',
        "router.pushReplacement('/profile', extra: user);",
      ];
      for (final sample in samples) {
        expect(offendersIn(sample), isNotEmpty, reason: sample);
      }
    });

    test('当ててはいけない形は当たらない', () {
      const samples = [
        'openPost(context, post);',
        'openProfile(context, user);',
        'openHashtag(context, tag);',
        // 自分のプロフィール編集はカラムにならない
        "context.push('/profile/edit');",
        // 別のパス
        "context.push('/posts', extra: fetcher);",
        "context.push('/hashtags');",
        // 遷移ではない比較
        "if (location == '/post') context.pop();",
        // コメント
        "// context.push('/post', extra: post) はしない",
      ];
      for (final sample in samples) {
        expect(offendersIn(sample), isEmpty, reason: sample);
      }
    });
  });

  group('⚠⚠ 歯があることを実物で確かめる', () {
    test('修正前の post_tile は当たる', () {
      // ⚠ SHA で固定する（`HEAD:` だと修正のコミット後に修正後のファイルを
      // 取り出して当たらなくなる）。`87752871` = #1149 の全画面 push 対応。
      // 投稿・プロフィールの遷移はまだ素のまま。
      final before = Process.runSync('git', [
        'show',
        '87752871:packages/capsicum/lib/src/ui/widget/post_tile.dart',
      ], workingDirectory: '../..');
      expect(before.exitCode, 0, reason: (before.stderr as String));
      expect(
        offendersIn(before.stdout as String).length,
        greaterThanOrEqualTo(7),
        reason: '投稿 2・プロフィール 5 箇所が素の push',
      );
    });
  });

  test('投稿・プロフィール・ハッシュタグは open* で開いている', () {
    final offenders = <String>[];
    for (final file in sources) {
      final path = file.path.replaceAll('\\', '/');
      if (allowlist.any(path.endsWith)) continue;
      for (final hit in offendersIn(file.readAsStringSync())) {
        offenders.add('$path: $hit');
      }
    }
    if (offenders.isNotEmpty) {
      fail(
        '投稿・プロフィール・ハッシュタグは openPost / openProfile / openHashtag '
        'で開くこと (#1148)。素の push だとデッキのカラムから開いても全画面になり、'
        '現在のアカウントで動く:\n${offenders.join('\n')}',
      );
    }
  });
}

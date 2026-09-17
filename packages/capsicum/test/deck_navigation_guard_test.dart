import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1148 / #1150: カラムの中身から開く画面は `deck_navigation.dart` の `open*` で
/// 開く（投稿・プロフィール・ハッシュタグ・チャンネル・ユーザー一覧・引用一覧・
/// 実績・コレクション・ギャラリー・Play・メッセージ）。
///
/// ⚠⚠ **素の `context.push('/post' …)` は、デッキのカラムの中から開いても全画面へ
/// 遷移し、ルートのスコープ（現在のアカウント）で動く。**カラム B の id を
/// アカウント A のアダプタで引くことになり、別の投稿・別のユーザーを指しうる
/// （id はサーバーローカル）。そのままフォローすると A として別人をフォローする。
///
/// ⚠ 対象外（理由つき）は [allowlist]。
void main() {
  final libDir = Directory('lib');
  final sources = libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  const allowlist = <String, String>{
    'lib/src/ui/util/deck_navigation.dart': '振り分けの本体',
    'lib/src/ui/screen/chat_new_thread_screen.dart':
        '新規メッセージ画面を相手とのメッセージ画面で置き換える（pushReplacement）。'
        'この画面自体がカラムの中身にならない',
    'lib/main.dart': '通知タップからの遷移。BuildContext を持たず、カラムの外',
  };

  // ⚠ `/profile/edit` は対象外（編集フォームはカラムにならず、スコープを運ぶ・
  // `provider_scope_push_guard_test`）なので、`/profile` は閉じ引用符まで含めて
  // 照合する。`/posts` と `/post`、`/collections` と `/collection` も同じ。
  // ⚠ 型引数は入れ子になりうる（`push<List<Attachment>>(`）。
  final pattern = RegExp(
    r'''\b(?:push|go|pushReplacement|replace)(?:<[^(]*>)?\(\s*['"]/'''
    r'''(?:(?:post|profile|posts|users|achievements|collections|collection|play)['"]'''
    r'''|hashtag/|channel/|gallery/|chat/user/)''',
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

    test('振り分けの本体（deck_navigation.dart）は、行き先 12 本すべてで当たる', () {
      // ⚠ これが減ったら、パターンが実物の書き方から外れている。
      final helper = File(
        'lib/src/ui/util/deck_navigation.dart',
      ).readAsStringSync();
      expect(offendersIn(helper), hasLength(12));
    });

    test('対象外の指定は実在し、実際に当たるものだけ（古い除外を残さない）', () {
      for (final path in allowlist.keys) {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: '$path は存在しない');
        expect(
          offendersIn(file.readAsStringSync()),
          isNotEmpty,
          reason: '$path は当たらないので除外は不要',
        );
      }
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
        "context.push(\n  '/users',\n  extra: {'title': t, 'fetcher': f},\n);",
        "context.push('/posts', extra: {'fetcher': f});",
        "context.push('/achievements', extra: {'userId': id});",
        "context.push('/collections', extra: {});",
        "await context.push('/collection', extra: c.id);",
        "context.push('/gallery/\${post.id}', extra: post);",
        "context.push('/play', extra: {'flashId': id});",
        "context.push('/chat/user/\${user.id}', extra: user);",
        "context.push('/channel/\$id', extra: name);",
      ];
      for (final sample in samples) {
        expect(offendersIn(sample), isNotEmpty, reason: sample);
      }
    });

    test('当ててはいけない形は当たらない', () {
      const samples = [
        'openPost(context, post);',
        'openProfile(context, user);',
        'openUserList(context, ref, tab);',
        // 編集フォームはカラムにならない（スコープを運ぶ）
        "context.push('/profile/edit', extra: extraWithProviderScope(context));",
        // 別のパス（一覧の画面そのもの・設定等）
        "context.push('/gallery');",
        "context.push('/chat');",
        "context.push('/chat/room/\$id');",
        "context.push('/hashtags');",
        "context.push('/settings/followed-hashtags');",
        // 遷移ではない比較
        "if (location == '/post') context.pop();",
        // コメント
        "// context.push('/users', extra: {}) はしない",
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
      // 投稿・プロフィール・一覧・チャンネルの遷移はまだ素のまま。
      final before = Process.runSync('git', [
        'show',
        '87752871:packages/capsicum/lib/src/ui/widget/post_tile.dart',
      ], workingDirectory: '../..');
      expect(before.exitCode, 0, reason: (before.stderr as String));
      expect(
        offendersIn(before.stdout as String).length,
        greaterThanOrEqualTo(14),
        reason: '投稿 2・プロフィール 5・ユーザー一覧 5・引用 1・チャンネル 1 が素の push',
      );
    });

    test('修正前の profile_screen は当たる', () {
      // `ea651431` = #1148。一覧・実績・コレクション・ギャラリー・メッセージは素のまま。
      final before = Process.runSync('git', [
        'show',
        'ea651431:packages/capsicum/lib/src/ui/screen/profile_screen.dart',
      ], workingDirectory: '../..');
      expect(before.exitCode, 0, reason: (before.stderr as String));
      expect(
        offendersIn(before.stdout as String).length,
        greaterThanOrEqualTo(6),
        reason: 'フォロー・フォロワー・実績・コレクション・ギャラリー・メッセージ',
      );
    });
  });

  test('カラムの中身から開く画面は open* で開いている', () {
    final offenders = <String>[];
    for (final file in sources) {
      final path = file.path.replaceAll('\\', '/');
      if (allowlist.keys.any(path.endsWith)) continue;
      for (final hit in offendersIn(file.readAsStringSync())) {
        offenders.add('$path: $hit');
      }
    }
    if (offenders.isNotEmpty) {
      fail(
        'カラムの中身から開く画面は deck_navigation.dart の open* で開くこと '
        '(#1148 / #1150)。素の push だとデッキのカラムから開いても全画面になり、'
        '現在のアカウントで動く:\n${offenders.join('\n')}',
      );
    }
  });
}

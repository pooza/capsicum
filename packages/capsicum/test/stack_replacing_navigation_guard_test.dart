import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/git_show.dart';
import 'support/source_files.dart';

/// #1319: 画面の積み重ねを丸ごと置き換える `go(...)` は、デッキを消す。
///
/// ⚠⚠ **デッキ（`/deck`）は `/home` の上に push した画面**（決定済み事項 8）なので、
/// `go('/home')` / `go('/chat')` のように積み重ねを置き換えると `/deck` ごと消え、
/// タブ表示に落ちる。デッキ（v2.0）より前に書かれた「投稿の後はタイムラインへ
/// 畳む」（#584）が、Annict の記録・感想・チャットのルームを抜けたときに残っていた。
///
/// 画面の中で書いてよいのは、**閉じる先が無いときの逃げ道**としての `go` だけ:
///
/// ```dart
/// if (context.canPop()) {
///   context.pop();
/// } else {
///   context.go('/home');
/// }
/// ```
///
/// ⚠ 判定は構造で見る: `go(` の手前に `canPop()` があり、その間に `else` がある
/// こと（＝ `canPop()` の else 側にある）。
///
/// ⚠ 対象外（意図して置き換える・理由つき）は [allowlist]。
void main() {
  final libDir = Directory('lib');
  final sources = sourceFiles(libDir.path);

  const allowlist = <String, String>{
    'lib/main.dart':
        '通知タップと共有の振り分け。ホームとデッキの上には積み、それ以外の'
        '画面にいるときだけ置き換える（_canPushOver）',
    'lib/src/router.dart': '起動のゲートと、extra を失ったときに一覧・ホームへ戻す逃げ道',
    'lib/src/ui/screen/splash_screen.dart': '起動の行き先を決める（積み重ねがまだ無い）',
    'lib/src/ui/screen/eula_screen.dart': '起動のゲートを抜けた先へ出す',
    'lib/src/ui/screen/login_screen.dart': 'ログインの後はホームへ出す（#1057）',
    'lib/src/ui/widget/oauth_scope_error_view.dart': 'ログインし直しのためにサーバーの選択へ出す',
    'lib/src/ui/widget/home_menu.dart': 'アカウントの切り替えと、デッキとタブ表示の切り替えそのもの',
    'lib/src/ui/screen/deck_screen.dart': 'デッキからタブ表示へ切り替える操作そのもの',
  };

  // `context.go(` / `router.go(` / `GoRouter.of(context).go(`。型引数は付かない。
  final goCall = RegExp(r'\.go\(');

  /// `canPop()` の else 側にある `go` か。手前の `canPop()` が遠すぎるものは
  /// 別の if とみなす（同じ関数の中の逃げ道だけを認める）。
  bool isPopFallback(String masked, int goIndex) {
    final before = masked.substring(0, goIndex);
    final canPopAt = before.lastIndexOf('canPop()');
    if (canPopAt < 0 || goIndex - canPopAt > 200) return false;
    return before.substring(canPopAt).contains('else');
  }

  List<String> offendersIn(String source) {
    final masked = maskComments(source);
    return [
      for (final match in goCall.allMatches(masked))
        if (!isPopFallback(masked, match.start))
          masked
              .substring(match.start, (match.end + 40).clamp(0, masked.length))
              .replaceAll(RegExp(r'\s+'), ' '),
    ];
  }

  group('⚠ 走査が空振りしていない', () {
    test('lib の走査が実際にファイルを拾っている', () {
      expect(sources.length, greaterThan(100));
    });

    test('逃げ道として書いた go は、実物の書き方で認められている', () {
      // ⚠ これが崩れたら、判定が実物の書き方から外れている（逃げ道まで
      // 違反扱いになるか、`go` を拾えていない）。
      for (final path in [
        'lib/src/ui/screen/annict_record_screen.dart',
        'lib/src/ui/screen/chat_room_timeline_screen.dart',
        'lib/src/ui/screen/compose_screen.dart',
      ]) {
        final masked = maskComments(File(path).readAsStringSync());
        expect(goCall.hasMatch(masked), isTrue, reason: '$path に go が無い');
        expect(offendersIn(masked), isEmpty, reason: path);
      }
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
    test('置き換える go は当たる', () {
      final samples = [
        "context.go('/home');",
        "if (!mounted) return;\ncontext.go('/chat');",
        "router.go('/compose', extra: extra);",
        "GoRouter.of(context).go('/home');",
        // canPop() の then 側に書いた go（逃げ道ではない）
        "if (context.canPop()) {\n  context.go('/home');\n}",
        // 遠く離れた別の if の else
        "if (context.canPop()) {\n  context.pop();\n} else {\n  doSomething();\n}\n"
            '${'final unrelated = compute(a, b, c, d, e, f, g, h, i, j);\n' * 4}'
            "context.go('/home');",
      ];
      for (final sample in samples) {
        expect(offendersIn(sample), isNotEmpty, reason: sample);
      }
    });

    test('当ててはいけない形は当たらない', () {
      const samples = [
        "if (context.canPop()) {\n  context.pop();\n} else {\n  context.go('/home');\n}",
        "if (context.canPop()) {\n  context.pop(true);\n} else {\n"
            "  context.go('/home');\n}",
        "context.canPop() ? context.pop() : null;",
        "context.push('/compose', extra: extra);",
        "context.pushReplacement('/chat/room/\$id', extra: room);",
        // コメント
        "// context.go('/home') はしない",
        // 別の名前
        "cargo('/home');",
      ];
      for (final sample in samples) {
        expect(offendersIn(sample), isEmpty, reason: sample);
      }
    });
  });

  group('⚠⚠ 歯があることを実物で確かめる', () {
    // ⚠ SHA で固定する（`HEAD:` だと修正のコミット後に修正後のファイルを取り出して
    // 当たらなくなる）。`b5d6147f` = #1319 の修正の直前（v2.5 の移行）。
    String before(String path) {
      final result = gitShow('b5d6147f:packages/capsicum/$path');
      expect(result.exitCode, 0, reason: (result.stderr as String));
      return result.stdout as String;
    }

    test('修正前の Annict の記録・感想は当たる', () {
      expect(
        offendersIn(before('lib/src/ui/screen/annict_record_screen.dart')),
        hasLength(1),
      );
      expect(
        offendersIn(before('lib/src/ui/screen/annict_review_screen.dart')),
        hasLength(1),
      );
    });

    test('修正前のチャットのルームは当たる', () {
      expect(
        offendersIn(before('lib/src/ui/screen/chat_room_timeline_screen.dart')),
        hasLength(2),
        reason: 'ルームを抜ける・削除する',
      );
    });
  });

  test('画面の中の go は、閉じる先が無いときの逃げ道だけ', () {
    final offenders = <String>[];
    for (final file in sources) {
      if (allowlist.containsKey(file.path)) continue;
      for (final hit in offendersIn(file.readAsStringSync())) {
        offenders.add('${file.path}: $hit');
      }
    }
    if (offenders.isNotEmpty) {
      fail(
        '積み重ねを置き換える go はデッキを消す (#1319)。閉じられるなら pop し、'
        'go は canPop() の else 側の逃げ道にだけ書く:\n${offenders.join('\n')}',
      );
    }
  });
}

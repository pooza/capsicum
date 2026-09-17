import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1149: 投稿フォーム（`/compose`）とメディアビューア（`/media`）へは、開く側の
/// スコープを `extraWithProviderScope` で載せて push する。
///
/// ⚠⚠ **素の `push('/compose', extra: {...})` は、デッキのカラム B から開いても
/// アカウント A（現在のアカウント）で投稿する。**go_router のページの route は
/// 開く側の `ProviderScope` を持ち込まないので、`ComposeScreen` はルートの
/// コンテナを読む。カラムのスコープは `extra` に載せて運び、ルーターの builder
/// が `withExtraProviderScope` で包み直す。
///
/// ⚠ 対象外: `main.dart`（共有インテント）と `splash_screen.dart`（起動時）は
/// アプリの入口から開くので、ルートのスコープで正しい。
void main() {
  final libDir = Directory('lib');
  final sources = libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  const allowlist = ['lib/main.dart', 'src/ui/screen/splash_screen.dart'];

  // ⚠ 型引数は入れ子になる（`push<List<Attachment>>(`）。`<[^>]*>` だと最初の
  // `>` で切れて当たらない（歯の確認で実際に取りこぼした）。
  final callStart = RegExp(
    r'''\b(?:push|go|pushReplacement)(?:<[^(]*>)?\(\s*['"]/(?:compose|media)['"]''',
  );

  /// 呼び出し全体（開き括弧から対応する閉じ括弧まで）を切り出す。
  List<String> callsIn(String source) {
    final masked = maskComments(source);
    final calls = <String>[];
    for (final match in callStart.allMatches(masked)) {
      final open = masked.indexOf('(', match.start);
      var depth = 0;
      for (var i = open; i < masked.length; i++) {
        final c = masked[i];
        if (c == '(') depth++;
        if (c == ')') depth--;
        if (depth == 0) {
          calls.add(masked.substring(match.start, i + 1));
          break;
        }
      }
    }
    return calls;
  }

  /// スコープを載せていない呼び出しを返す。
  ///
  /// `extra:` が変数なら、同じファイルでその変数を `extraWithProviderScope` で
  /// 作っていれば通す（`await` を挟む前に作っておく書き方・post_tile の削除して
  /// 再編集）。
  List<String> offendersIn(String source) {
    final masked = maskComments(source);
    final offenders = <String>[];
    for (final call in callsIn(source)) {
      if (call.contains('extraWithProviderScope(')) continue;
      final variable = RegExp(r'extra:\s*(\w+)\s*[,)]').firstMatch(call);
      if (variable != null &&
          RegExp(
            '\\b${variable.group(1)}\\s*=\\s*extraWithProviderScope\\(',
          ).hasMatch(masked)) {
        continue;
      }
      offenders.add(call.replaceAll(RegExp(r'\s+'), ' '));
    }
    return offenders;
  }

  group('⚠ 走査が空振りしていない', () {
    test('lib の走査が実際にファイルを拾っている', () {
      expect(sources.length, greaterThan(100));
    });

    test('実物の push を実際に切り出している', () {
      // ⚠ これが減ったら、パターンが実物の書き方から外れている。
      final calls = [
        for (final file in sources) ...callsIn(file.readAsStringSync()),
      ];
      expect(calls.length, greaterThanOrEqualTo(15));
    });
  });

  group('⚠ 判定に合成ソースを食わせる', () {
    test('スコープを載せていない呼び出しは当たる', () {
      const samples = [
        "context.push('/compose');",
        "context.push('/compose', extra: {'replyTo': post});",
        "context.push<bool>(\n  '/compose',\n  extra: extra.isNotEmpty ? extra : null,\n);",
        "router.push('/compose', extra: redraftExtra);",
        "context.pushReplacement('/compose', extra: {'template': t});",
        "context.go('/media', extra: {'attachments': [a], 'initialIndex': 0});",
        "await context.push<List<Attachment>>(\n  '/media',\n  extra: {'attachments': a},\n);",
        // 別の呼び出しの中で使っていても、この呼び出しに載っていなければ当たる
        "context.push('/media', extra: {'label': f(extraWithProviderScope)});",
      ];
      for (final sample in samples) {
        expect(offendersIn(sample), isNotEmpty, reason: sample);
      }
    });

    test('当ててはいけない形は当たらない', () {
      const samples = [
        "context.push('/compose', extra: extraWithProviderScope(context));",
        "context.push(\n  '/media',\n  extra: extraWithProviderScope(context, {\n    'attachments': [a],\n  }),\n);",
        "final redraftExtra = extraWithProviderScope(context, {'redraft': p});\n"
            "await showDialog(context: context, builder: b);\n"
            "router.push('/compose', extra: redraftExtra);",
        // 別のパス
        "context.push('/composer');",
        "context.push('/media_catalog');",
        "context.push('/post', extra: post);",
        // コメントでの言及
        "// context.push('/compose') はしない",
      ];
      for (final sample in samples) {
        expect(offendersIn(sample), isEmpty, reason: sample);
      }
    });
  });

  group('⚠⚠ 歯があることを実物で確かめる', () {
    test('修正前の post_tile は当たる', () {
      // ⚠ SHA で固定する（`HEAD:` だと修正のコミット後に修正後のファイルを
      // 取り出して当たらなくなる）。`55081ceb` = #1149 のシート・ダイアログ対応。
      // 全画面の push はまだ素のまま。
      final before = Process.runSync('git', [
        'show',
        '55081ceb:packages/capsicum/lib/src/ui/widget/post_tile.dart',
      ], workingDirectory: '../..');
      expect(before.exitCode, 0, reason: (before.stderr as String));
      final offenders = offendersIn(before.stdout as String);
      expect(
        offenders.length,
        greaterThanOrEqualTo(4),
        reason: '返信・引用・削除して再編集・メディアビューアの 4 箇所が素の push',
      );
    });
  });

  test('/compose と /media への push はスコープを載せている', () {
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
        '/compose と /media へは extraWithProviderScope(context, …) で push '
        'すること (#1149)。素のままだとカラムから開いても現在のアカウントで'
        '動く:\n${offenders.join('\n')}',
      );
    }
  });
}

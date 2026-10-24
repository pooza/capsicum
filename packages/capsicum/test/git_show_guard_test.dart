import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/git_show.dart';
import 'support/source_files.dart';

/// #1301: 修正前の版を `git show` で読む歯の確認を、Windows でも成立させる。
///
/// ## 何が起きていたか
///
/// Windows 機（x64）で `packages/capsicum` の全テストを流すと、修正前の版を
/// `git show` で読む歯の確認が **6 件落ちていた**（CI の Linux と macOS では緑）。
/// `Process.runSync` に `stdoutEncoding` を渡しておらず、日本語版の Windows の
/// [systemEncoding]（CP932）で UTF-8 のソースを読んでいたため。
///
/// ⚠⚠ **逆向きの穴のほうが危ない。**化けて潰れたソースは「無い」側の検査を
/// 何でも通すので、**落ちた 6 件のほかに、緑のまま空振りしていたものがありうる**。
///
/// ## この検査が見るもの
///
/// `docs/CLAUDE.md`「ソース検査ガードの書き方」の 3 点セットに沿う。
///
/// 1. 走査が空振りしていないこと（`test` を読めている・ヘルパーの利用者がいる）
/// 2. 判定（[bareGitCalls]）に合成ソースを直接食わせる
/// 3. ⚠⚠ **歯があること** —— 置き換える前の版を食わせて当たること、
///    日本語が UTF-8 のまま読めること
void main() {
  const helper = 'test/support/git_show.dart';

  group('判定ロジック: 素の git の呼び出し (#1301)', () {
    test('runSync と run の両方を拾う', () {
      expect(
        bareGitCalls('''
final a = Process.runSync('git', ['show', spec]);
final b = await Process.run(
  'git',
  ['log'],
);
'''),
        2,
      );
    });

    test('git 以外のコマンドは拾わない', () {
      expect(bareGitCalls("Process.runSync('flutter', ['--version']);"), 0);
    });

    test('コメントと文字列の中の綴りは拾わない', () {
      expect(
        bareGitCalls('''
// Process.runSync('git', ['show', spec]) を直に書かない
final reason = "Process.runSync('git' は使わない";
'''),
        0,
      );
    });

    test('ヘルパー経由の呼び出しは拾わない', () {
      expect(bareGitCalls("final r = gitShow('HEAD:README.md');"), 0);
    });
  });

  group('⚠⚠ 歯があること (#1301)', () {
    /// 置き換える前の HEAD（#1301 の修正の親）。
    const preFix = '6add29e8';

    test('置き換える前の歯の確認は、素の git を呼んでいた', () {
      for (final path in const [
        'relay_wording_guard_test.dart',
        'push_token_and_restore_guard_test.dart',
        'relay_purchase_entry_guard_test.dart',
      ]) {
        final shown = gitShow('$preFix:packages/capsicum/test/$path');
        expect(shown.exitCode, 0, reason: '$path: ${shown.stderr}');
        expect(
          bareGitCalls(shown.stdout as String),
          greaterThan(0),
          reason: '$path の修正前の素の呼び出しを捕まえられていない',
        );
      }
    });

    test('日本語を含むソースが UTF-8 のまま読める', () {
      // ⚠ Windows で落ちていたのはこれ。化けると日本語の doc もソースの
      // 引用符も崩れ、`maskComments` が後ろを丸ごと空白に潰す。
      final shown = gitShow('$preFix:packages/capsicum/$helperOfSourceFiles');
      expect(shown.exitCode, 0, reason: '${shown.stderr}');
      expect(shown.stdout as String, contains('ソースを文字列で走査するガード群が共有する'));
    });

    test('⚠ 符号化を指定しないと、Windows では日本語が化ける（原因そのもの）', () {
      final raw = Process.runSync(
        'git',
        ['show', '$preFix:packages/capsicum/$helperOfSourceFiles'],
        workingDirectory: '../..',
        stdoutEncoding: null,
      );
      expect(raw.exitCode, 0, reason: '${raw.stderr}');
      final bytes = raw.stdout as List<int>;
      const marker = 'ソースを文字列で走査するガード群が共有する';
      expect(utf8.decode(bytes), contains(marker));
      // ⚠ macOS / Linux は systemEncoding が UTF-8 なので化けない。
      // `systemEncoding.name` は OS を問わず 'system' なので、名前では
      // 見分けられない。実際に読ませて決める。
      if (systemEncoding.decode(bytes).contains(marker)) {
        markTestSkipped('systemEncoding が UTF-8 の端末では再現しない');
        return;
      }
      expect(Platform.isWindows, isTrue, reason: '化けるのは Windows のはず');
    });
  });

  group('走査が空振りしていない', () {
    test('test を読めていて、ヘルパーの利用者がいる', () {
      final files = sourceFiles('test', extension: '_test.dart');
      expect(files.length, greaterThan(50), reason: 'test を読めていない');
      final users = [
        for (final file in files)
          if (maskStrings(
            maskComments(file.readAsStringSync()),
          ).contains('gitShow('))
            file.path,
      ];
      expect(users.length, greaterThanOrEqualTo(20));
      expect(users, contains('test/relay_wording_guard_test.dart'));
    });

    test('⚠ ヘルパー自身は素の git を呼んでいる（探している綴りが実物と合う）', () {
      // 「素の呼び出しが無い」だけを見ると、綴りを間違えていても緑になる。
      expect(
        bareGitCalls(File(helper).readAsStringSync()),
        1,
        reason: '$helper が git を呼ばなくなった。この検査の綴りも直す',
      );
    });
  });

  group('git の呼び出しはヘルパーへ寄せる (#1301)', () {
    test('test 配下で Process.run(Sync) の git を直に書かない', () {
      final offenders = <String>[];
      for (final file in sourceFiles('test')) {
        if (file.path == helper) continue;
        // ⚠ 上の「原因そのもの」の検査は、化けることを見せるために符号化を
        // 外して呼ぶ。ここだけは意図して素で書く。
        if (file.path == 'test/git_show_guard_test.dart') continue;
        if (bareGitCalls(file.readAsStringSync()) > 0) {
          offenders.add(file.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            '修正前の版は $helper の gitShow() で読むこと。'
            '素の Process.runSync は Windows で CP932 として読み、'
            'UTF-8 のソースが化ける (#1301)'
            '\n${offenders.join('\n')}',
      );
    });
  });
}

/// 日本語の doc を持つ既知のファイル（歯の確認で読む）。
const helperOfSourceFiles = 'test/support/source_files.dart';

/// [source] の中で、`Process.run` / `Process.runSync` の第 1 引数に `'git'` を
/// 直に渡している箇所の数。
///
/// ⚠ 判定は「コメントだけ潰した」ソースで `'git'` を見て、その位置が
/// 「文字列の中身も潰した」ソースでもコードとして残っているかで、文字列の中の
/// 綴り（`reason:` の説明文）を外す。[maskStrings] は `'git'` 自体も潰すので、
/// 片方だけでは見分けられない。
int bareGitCalls(String source) {
  final noComments = maskComments(source);
  final code = maskStrings(noComments);
  final pattern = RegExp(r"""Process\.run(Sync)?\(\s*['"]git['"]""");
  return pattern
      .allMatches(noComments)
      .where((m) => code.startsWith('Process.run', m.start))
      .length;
}

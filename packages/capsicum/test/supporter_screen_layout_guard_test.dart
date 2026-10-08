import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1225: 投げ銭画面は**グレーの帯**で区切り、**投げ銭を利用権より先**に出す。
///
/// ## なぜ要るか
///
/// ⚠⚠ **この画面は投げ銭のための画面なのに、利用権のほうが目立っていた**
/// （2026-10-04 pooza）。⚠ 以前のコメントは「機能に対する対価なので利用権が先」と
/// していたが、**それは実装時の判断で設計書の決定ではなかった**
/// （`docs/paid-relay-plan.md` の決定済み事項 3 は「投げ銭を残したままサブスクを
/// 追加する」としか言っていない）。⚠⚠ **入れ替えは再提案しない決定**なので、
/// 順序をここで固定する。
///
/// ⚠ 見た目のほうも、**設定画面の中でこの画面だけ**が太字 `Text` + `Divider` で、
/// 他 3 つ（プッシュ通知 / アカウント / 外観）は `SectionHeader`（グレーの帯）で
/// `Divider` を 0 件にしていた。
///
/// ## 対象をこの画面に絞る理由
///
/// ⚠ **「設定画面は `Divider` を使わない」という全体規約にはしない。**
/// `settings_backup_screen.dart` が `Divider` を 1 件持っており（2026-10-04 実測）、
/// あの画面の見え方は #1225 の依頼範囲外。**全体へ広げるなら、あちらの扱いを
/// 決めてからにする**（許可リストを持つと、次に増えた画面が黙って通る）。
void main() {
  const path = 'lib/src/ui/screen/settings/supporter_screen.dart';

  /// 投げ銭の商品一覧より**前**に利用権の節が出ていれば違反。
  ///
  /// ⚠ 見出しの綴りではなく**構造**で見る（`docs/CLAUDE.md`「ソース検査ガードの
  /// 書き方」）。見出し文言は変わりうるが、「商品一覧の `for`」と「利用権の節を
  /// 呼ぶ `_subscriptionSection`」は構造なので、言い換えでは逃げられない。
  bool subscriptionComesFirst(String source) {
    final masked = maskComments(source);
    final products = masked.indexOf('for (final product in state.products)');
    final subscription = masked.indexOf('..._subscriptionSection(state)');
    if (products == -1 || subscription == -1) return false;
    return subscription < products;
  }

  /// `Divider` を組んでいる行。
  ///
  /// ⚠ `Divider(` の**呼び出しの形**で見る。`DividerThemeData` のような識別子に
  /// 当てないため。
  List<String> dividersIn(String source) {
    final masked = maskComments(source);
    final lines = masked.split('\n');
    final hits = <String>[];
    for (var i = 0; i < lines.length; i++) {
      if (RegExp(r'\bDivider\(').hasMatch(lines[i])) {
        hits.add('${i + 1}: ${lines[i].trim()}');
      }
    }
    return hits;
  }

  String read() => File(path).readAsStringSync();

  group('⚠ 走査が空振りしていない', () {
    test('画面が読めている', () {
      expect(File(path).existsSync(), isTrue, reason: path);
      expect(read().length, greaterThan(2000));
    });

    test('⚠⚠ 探している構造が実在する', () {
      // ⚠ 綴りが実物から外れると、**順序も Divider も「無い」で緑になる**。
      final masked = maskComments(read());
      expect(
        masked,
        contains('for (final product in state.products)'),
        reason: '投げ銭の商品一覧',
      );
      expect(
        masked,
        contains('..._subscriptionSection(state)'),
        reason: '利用権の節',
      );
    });

    test('⚠ グレーの帯を実際に使っている', () {
      final headers = RegExp(
        r"SectionHeader\('",
      ).allMatches(maskComments(read())).length;
      expect(headers, greaterThanOrEqualTo(3), reason: 'SectionHeader の件数');
    });
  });

  group('⚠ 判定に合成ソースを食わせる', () {
    test('利用権が先なら当たる', () {
      const sample = '''
return [
  ..._subscriptionSection(state),
  for (final product in state.products) ListTile(),
];
''';
      expect(subscriptionComesFirst(sample), isTrue);
    });

    test('投げ銭が先なら当たらない', () {
      const sample = '''
return [
  for (final product in state.products) ListTile(),
  ..._subscriptionSection(state),
];
''';
      expect(subscriptionComesFirst(sample), isFalse);
    });

    test('⚠ コメントの中の順序は数えない', () {
      // ⚠ 「以前は利用権が先だった」と説明を書いただけで当たると、検査ごと
      // 外されてしまう。
      const sample = '''
// 以前は ..._subscriptionSection(state) が先だった
return [
  for (final product in state.products) ListTile(),
  ..._subscriptionSection(state),
];
''';
      expect(subscriptionComesFirst(sample), isFalse);
    });

    test('Divider の判定は呼び出しの形で見る', () {
      expect(dividersIn('const Divider(height: 1),'), isNotEmpty);
      expect(dividersIn('const Divider(),'), isNotEmpty);
      // ⚠ テーマの型名には当てない。
      expect(dividersIn('dividerTheme: const DividerThemeData(),'), isEmpty);
      // ⚠ コメントには当てない。
      expect(dividersIn('// const Divider(), は使わない'), isEmpty);
    });
  });

  group('⚠⚠ 歯があることを、実物で穴を開けて確かめる', () {
    test('修正前の supporter_screen は両方の検査に当たる', () {
      // ⚠⚠ **SHA で固定する。**`HEAD:` だと #1225 の修正がコミットされた瞬間に
      // **修正後**のファイルを取り出して当たらなくなる。`5c915b11` は #1225 /
      // #1226 を入れる直前の develop の tip。`analyze.yml` は `fetch-depth: 0`
      // なので CI でも引ける。
      final before = Process.runSync('git', [
        'show',
        '5c915b11:packages/capsicum/$path',
      ], workingDirectory: '../..');
      expect(before.exitCode, 0, reason: (before.stderr as String));
      final source = before.stdout as String;
      expect(
        source,
        contains('_buildPurchaseSection'),
        reason: '取り出したのが本当に修正前のファイルであること',
      );
      expect(
        subscriptionComesFirst(source),
        isTrue,
        reason: '修正前は利用権が先だったので、当たらなければ歯が無い',
      );
      expect(
        dividersIn(source),
        isNotEmpty,
        reason: '修正前は Divider を使っていたので、当たらなければ歯が無い',
      );
    });
  });

  test('⚠⚠ 投げ銭が利用権より先に出る（再提案しない・#1225）', () {
    expect(
      subscriptionComesFirst(read()),
      isFalse,
      reason: 'この画面は投げ銭のための画面。利用権を先に出さない',
    );
  });

  test('⚠ 区切りはグレーの帯に寄せる（Divider を混ぜない）', () {
    expect(dividersIn(read()), isEmpty, reason: '帯と罫線を両方残すと二重の区切りになる。#1225');
  });
}

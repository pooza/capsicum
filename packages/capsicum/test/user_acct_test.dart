import 'dart:io';

import 'package:capsicum/src/util/user_acct.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1027-D: `user@host` の組み立てを [userAcct] 1 箇所に寄せる。
///
/// ⚠⚠ **散らしていた結果、実際に壊れていた。**doc は「single source of truth」を
/// 名乗っていたのに 7 箇所で再実装されており、そのうち 2 箇所は**ガードごと
/// 落ちていた**:
///
/// - `user_list_screen` / `search_screen` … `'@${user.username}@${user.host}'`
///   を素で書いており、**ローカルユーザー（`host == null`）に `@alice@null`**
///   と表示していた
/// - `profile_screen` … `?? ''` で潰していたので `@alice@`（末尾に `@`）
/// - チャット 3 画面 … ガードは正しいが同じ三項を 3 回書いていた
///   （空文字列の host は考慮されていない）
void main() {
  User user({required String username, String? host}) =>
      User(id: 'x', username: username, host: host);

  group('userAcct', () {
    test('リモートユーザーは user@host', () {
      expect(
        userAcct(user(username: 'alice', host: 'mstdn.example')),
        'alice@mstdn.example',
      );
    });

    // ⚠ ここが壊れていた形。`'$username@$host'` を素で書くと `alice@null`。
    test('ローカルユーザー（host が null）は username だけ', () {
      expect(userAcct(user(username: 'alice')), 'alice');
    });

    // ⚠ 空文字列の host も「ローカル」。三項の再実装はここを落としていた。
    test('host が空文字列でも username だけ', () {
      expect(userAcct(user(username: 'alice', host: '')), 'alice');
    });
  });

  /// ⚠ **再実装が戻らないようにする。**「single source of truth」と doc に
  /// 書くだけでは守られなかった（#1027-D で 7 箇所見つかった）。
  ///
  /// ## ⚠⚠ 2026-09-06: 検査が 1 つの書き方しか見ていなかった (#1035-C4)
  ///
  /// 旧実装は `\$\{?user\.username\}?@\$\{?user\.host` という**変数名 `user` と
  /// 直後の `@$` を要求する**正規表現だった。実際には 2 つの書き方が残っていた:
  ///
  /// - `post_tile.dart` の `_handleText(User author)` — **変数名が `author`**
  /// - `account_multi_select_sheet.dart` — `'@${user.username}${user.host != null
  ///   ? '@${user.host}' : ''}'`（**`username` と `host` の間に三項が挟まる**）
  ///
  /// 塞ぐついでに走査したら、**同型が 3 ファイル・計 5 箇所**あった
  /// （`list_members_screen` ×2 / `collection_detail_screen` ×2 を追加で発見）。
  /// どれも `host != null` は見ているが **`host == ''` を見ていない** ——
  /// [userAcct] が潰した分岐だけが落ちている形。
  ///
  /// ## どう見るか — 変数名ではなく「null ガードの有無」で見分ける
  ///
  /// 探すのは **`@` の直後に補間された `.host`**。これが acct 組み立ての印。
  /// ただし `AccountKey.host` は**非 null** なので、`'@${account.key.username}@'
  /// '${account.key.host}'` は正しい（[userAcct] は `User` を取るので使えない）。
  ///
  /// ⚠ **型が見えないので、型の代わりに「同じ receiver への null ガードが
  /// 同じファイルにあるか」で判定する。**`host` を null 比較しているなら、
  /// それは `User`（nullable）であって `AccountKey` ではない。
  /// **変数名の列挙に戻さない**のがこの判定の要点。
  test('acct の組み立てを再実装しない (#1027-D / #1035-C4)', () {
    /// `@` の直後に補間された `.host`。receiver を捕まえる。
    final acctFromHost = RegExp(r'@\$\{?([A-Za-z_][A-Za-z0-9_.]*)\.host');

    /// 同じ receiver の `host` を null 比較しているか（＝ nullable ＝ `User`）。
    bool nullableHost(String source, String chain) => RegExp(
      '${RegExp.escape(chain)}'
      r'\.host\s*(?:[!=]=\s*null|\?\?)',
    ).hasMatch(source);

    final offenders = <String>[];
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      if (file.path == 'lib/src/util/user_acct.dart') continue;
      final source = maskComments(file.readAsStringSync());
      for (final m in acctFromHost.allMatches(source)) {
        final chain = m.group(1)!;
        if (!nullableHost(source, chain)) continue; // AccountKey 系は対象外
        offenders.add('${file.path}: @\${$chain.host} → userAcct(...)');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'userAcct(user) を使うこと。素で組み立てると、ローカルユーザーで '
          '`@alice@null` / `@alice@`（空 host）になる'
          '\n${offenders.join('\n')}',
    );
  });

  /// ⚠ **リポジトリが綺麗だと常に緑になる検査なので、歯を別途固定する。**
  /// #1035-C4 は「正規表現が 1 つの書き方しか見ていない」という穴だったので、
  /// **書き方ごとに当たることを合成ソースで押さえる。**
  group('再実装の検出 (#1035-C4)', () {
    List<String> detect(String source) {
      final acctFromHost = RegExp(r'@\$\{?([A-Za-z_][A-Za-z0-9_.]*)\.host');
      bool nullableHost(String s, String chain) => RegExp(
        '${RegExp.escape(chain)}'
        r'\.host\s*(?:[!=]=\s*null|\?\?)',
      ).hasMatch(s);
      final masked = maskComments(source);
      return [
        for (final m in acctFromHost.allMatches(masked))
          if (nullableHost(masked, m.group(1)!)) m.group(1)!,
      ];
    }

    test('素の連結を拾う', () {
      expect(
        detect(
          r"""final a = user.host != null ? '@${user.username}@${user.host}' : '';""",
        ),
        isNotEmpty,
      );
    });

    test('変数名が user でなくても拾う', () {
      // post_tile の `_handleText(User author)` の形。
      expect(
        detect(r"""
if (author.host != null) {
  return '$handle@${author.host}';
}
"""),
        isNotEmpty,
      );
    });

    test('username と host の間に三項が挟まっても拾う', () {
      // account_multi_select_sheet / list_members / collection_detail の形。
      expect(
        detect(
          r"""Text('@${user.username}${user.host != null ? '@${user.host}' : ''}')""",
        ),
        isNotEmpty,
      );
    });

    test('AccountKey（host が非 null）は拾わない', () {
      // null 比較が無い＝ nullable ではない＝ userAcct の対象外。
      expect(
        detect(
          r"""final a = '@${account.key.username}@${account.key.host}';""",
        ),
        isEmpty,
      );
    });

    test('コメント中の例は拾わない', () {
      expect(
        detect(r"""// 昔は '@${user.username}@${user.host}' と書いていた
final ok = user.host != null;"""),
        isEmpty,
      );
    });
  });
}

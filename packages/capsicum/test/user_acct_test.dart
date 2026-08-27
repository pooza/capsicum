import 'dart:io';

import 'package:capsicum/src/util/user_acct.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

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
  test('acct の組み立てを再実装しない', () {
    final reimplementation = RegExp(r'\$\{?user\.username\}?@\$\{?user\.host');
    final offenders = <String>[];
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      if (file.path == 'lib/src/util/user_acct.dart') continue;
      if (reimplementation.hasMatch(file.readAsStringSync())) {
        offenders.add(file.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'userAcct(user) を使うこと。素で組み立てると、ローカルユーザーで '
          '`@alice@null` になる（実際にユーザー一覧と検索結果で起きていた）'
          '\n${offenders.join('\n')}',
    );
  });
}

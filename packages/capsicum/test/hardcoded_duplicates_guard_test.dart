import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// #1372: 同じ組み立てを各所に写さない。
///
/// - 絵文字の補完 URL（`https://<host>/emoji/<shortcode>.webp`）は 20 か所に
///   写されていた → `util/emoji_url.dart` の `fallbackEmojiUrl`
/// - アカウントの `@username@host` は約 20 か所に写されていた →
///   `AccountKey.handle`
///
/// ⚠ 判定はコメントを落としてから見る（説明の中の例は数えない）。文字列は
/// 落とさない（見たいのは文字列の中身）。
const _emojiUrlPath = 'lib/src/util/emoji_url.dart';
const _accountKeyPath = 'lib/src/model/account_key.dart';

final _emojiUrlPattern = RegExp(r'/emoji/\$');
final _handlePattern = RegExp(r'@\$\{[A-Za-z_.!?]+\.username\}@\$\{');

/// [source] の中で、写しになっている行番号。
List<int> offendingLines(String source, RegExp pattern) {
  final masked = maskComments(source);
  return [
    for (final m in pattern.allMatches(masked))
      '\n'.allMatches(masked.substring(0, m.start)).length + 1,
  ];
}

void main() {
  final files = sourceFiles('lib', skipGenerated: true);

  test('絵文字の補完 URL を fallbackEmojiUrl の外で組まない', () {
    final offenders = <String>[
      for (final f in files)
        if (f.path != _emojiUrlPath)
          for (final line in offendingLines(
            f.readAsStringSync(),
            _emojiUrlPattern,
          ))
            '${f.path}:$line',
    ];
    expect(offenders, isEmpty);
  });

  test('アカウントの @username@host を AccountKey.handle の外で組まない', () {
    final offenders = <String>[
      for (final f in files)
        if (f.path != _accountKeyPath)
          for (final line in offendingLines(
            f.readAsStringSync(),
            _handlePattern,
          ))
            '${f.path}:$line',
    ];
    expect(offenders, isEmpty);
  });

  group('走査が空振りしていない', () {
    String read(String path) =>
        files.firstWhere((f) => f.path == path).readAsStringSync();

    test('正本が列挙に入っていて、置き換え後の形がある', () {
      expect(read(_emojiUrlPath), contains('String fallbackEmojiUrl('));
      expect(read(_accountKeyPath), contains('String get handle =>'));
    });

    test('置き換えた先が実際に使われている', () {
      var emoji = 0;
      var handle = 0;
      for (final f in files) {
        final masked = maskComments(f.readAsStringSync());
        emoji += 'fallbackEmojiUrl('.allMatches(masked).length;
        handle += RegExp(r'\.handle\b').allMatches(masked).length;
      }
      // 置き換えた時点で 20 か所・約 20 か所。大きく減ったら列挙が壊れている。
      expect(emoji, greaterThanOrEqualTo(15));
      expect(handle, greaterThanOrEqualTo(15));
    });
  });

  group('判定（合成ソース）', () {
    test('絵文字の URL の写しを拾う', () {
      expect(
        offendingLines(
          "x\nreturn 'https://\$host/emoji/\$shortcode.webp';",
          _emojiUrlPattern,
        ),
        [2],
      );
      expect(
        offendingLines(
          "'https://\${widget.host}/emoji/\$s.webp'",
          _emojiUrlPattern,
        ),
        [1],
      );
    });

    test('アカウントの @username@host の写しを拾う', () {
      for (final src in [
        "'@\${account.key.username}@\${account.key.host}'",
        "'@\${a.user.username}@\${a.key.host}'",
        "'@\${column.account.username}@\${column.account.host}'",
      ]) {
        expect(offendingLines(src, _handlePattern), [1], reason: src);
      }
    });

    test('コメントの中の例は数えない', () {
      expect(
        offendingLines(
          "// 'https://\$host/emoji/\$shortcode.webp'\n"
          "/// '@\${a.username}@\${a.host}'",
          _emojiUrlPattern,
        ),
        isEmpty,
      );
      expect(
        offendingLines("// '@\${a.username}@\${a.host}'", _handlePattern),
        isEmpty,
      );
    });

    test('置き換え後の形は拾わない', () {
      expect(
        offendingLines(
          'fallbackEmojiUrl(host, shortcode); account.key.handle;',
          _emojiUrlPattern,
        ),
        isEmpty,
      );
      expect(
        offendingLines("final a = '@\$name@\$host';", _handlePattern),
        isEmpty,
        reason: 'アカウントでない acct（メンション）は対象外',
      );
    });
  });
}

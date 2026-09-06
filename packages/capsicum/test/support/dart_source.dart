/// ソースを文字列で読むガード群が共有する、Dart ソースの前処理 (#1035-C5)。
///
/// ## なぜ共有するのか
///
/// ガードは `lib` の Dart ソースを**文字列として**走査する。ウィジェットツリーを
/// 組み立てず静的に見るのは、対象が数十ファイルに散っていて pump の足場を用意する
/// コストに見合わないため。その代わり、**コメントと文字列リテラルの扱いを間違える
/// と検査が黙って空振りする**。
///
/// ⚠⚠ **実際に 3 本が同じ間違いをしていた (#1035-C5)。**
/// `phase_tag_literal_guard_test` / `link_routing_guard_test` /
/// `account_cleanup_symmetry_guard_test` はいずれも
///
/// ```dart
/// final i = line.indexOf('//');
/// return i == -1 ? line : line.substring(0, i);
/// ```
///
/// という素朴な行コメント落としを**それぞれ写して**持っていた。同一行に URL
/// リテラル（`'https://…'`）が先行すると、**そこから行末までが丸ごと消える**ので
/// 検出対象が消える。`link_routing_guard_test` は doc で「素朴に切って構わない」と
/// 許容判断済みだったが、3 本とも同じ実装の写しなので、リテラルを見る版
/// （[maskComments]・`exception_scrub_guard_test` が持っていた）へ寄せた。
library;

/// コメントを**同じ長さの空白**へ潰す。改行は残すので index も行番号もずれない。
///
/// ⚠ **括弧の対応付けはコメントを読んではいけない（#1020・Codex P2 の 6 巡目）。**
/// 本体に `// payload は {'key': value} の形` のような行があると、括弧の対応を
/// 取る側がその `}` を数えて**本体がそこで終わったことになる**。以降の
/// `debugPrint(message)` が本体の外に出るので、そのラッパーは sink から漏れ、
/// `log('failed: $e')` が緑のまま通る。
///
/// ⚠ **文字列リテラルの中の `//` で切らない (#1035-C5)。**`'https://…'` を
/// 含む行が丸ごと消える。
///
/// 潰しておくと**コメントアウトされたコードを違反として数えない**副次効果もある
/// （`// debugPrint('$e')` は実行されないので、直せと言われても困る）。
String maskComments(String source) {
  final out = StringBuffer();
  String? quote;
  for (var i = 0; i < source.length; i++) {
    final c = source[i];
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < source.length) {
        out.write(source[i + 1]);
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      continue;
    }
    if (c == '/' && i + 1 < source.length && source[i + 1] == '/') {
      while (i < source.length && source[i] != '\n') {
        out.write(' ');
        i++;
      }
      if (i < source.length) out.write('\n');
      continue;
    }
    if (c == '/' && i + 1 < source.length && source[i + 1] == '*') {
      // ⚠ **Dart のブロックコメントは入れ子にできる。**最初の `*/` で止めると
      // 外側の残りがコードとして読まれ、そこに `}` があれば本体が切れる。
      var depth = 0;
      while (i < source.length) {
        final open =
            source[i] == '/' && i + 1 < source.length && source[i + 1] == '*';
        final close =
            source[i] == '*' && i + 1 < source.length && source[i + 1] == '/';
        if (open) depth++;
        if (close) depth--;
        if (open || close) {
          out.write('  ');
          i += 2;
          if (close && depth == 0) break;
          continue;
        }
        out.write(source[i] == '\n' ? '\n' : ' ');
        i++;
      }
      // 外側の for が i++ するので 1 戻す。
      i--;
      continue;
    }
    out.write(c);
  }
  return out.toString();
}

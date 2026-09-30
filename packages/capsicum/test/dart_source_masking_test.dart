import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// `support/dart_source.dart` のマスキング自身を固定する（2026-09-30）。
///
/// ## なぜ要るか
///
/// ⚠⚠ **生文字列の中の `\` をエスケープとして読んでいた。**`r'\'` は「`\` 1 文字」
/// で直後の `'` は閉じ引用符なのに、それを食べてしまうため、**そこから次の引用符
/// までの実コードが文字列の中身として扱われる**。[maskStrings] はそれを空白へ
/// 潰すので、**続く行の違反が検査から消えて、ガードは緑のまま通る**
/// （`docs/CLAUDE.md`「ソース検査ガードの書き方」が言う「判定が壊れても緑」の型）。
///
/// ⚠ 合成ではなく**実物がある**: `lib/src/service/settings_backup.dart` の
/// YAML パーサが `if (text[i] == r'\') {` と書いている。
///
/// ⚠ この検査の合成ソースでは `r'…'` を**書かない**（このファイル自身を走査する
/// 検査があるので、生文字列を埋め込むと今度はそちらがずれる）。`'\\'` で
/// 1 文字の `\` を作る。
void main() {
  /// 直す前のマスキング。**生文字列を知らない版**（`\` を常にエスケープとして読む）。
  /// ⚠⚠ これが「歯があること」の比較相手。
  String naiveMaskStrings(String source) {
    final out = StringBuffer();
    for (var i = 0; i < source.length; i++) {
      final c = source[i];
      if (c != "'" && c != '"') {
        out.write(c);
        continue;
      }
      out.write(c);
      i++;
      while (i < source.length) {
        if (source[i] == '\\') {
          out.write('  ');
          i += 2;
          continue;
        }
        if (source[i] == c) break;
        if (source[i] == '\n') break;
        out.write(source[i] == '\n' ? '\n' : ' ');
        i++;
      }
      if (i < source.length && source[i] == c) out.write(c);
    }
    return out.toString();
  }

  group('判定ロジック: 生文字列を見分ける', () {
    test('r の直後の引用符は生文字列', () {
      expect(isRawStringStart("a = r'x'", 5), isTrue);
      expect(isRawStringStart('a = r"x"', 5), isTrue);
    });

    test('識別子の末尾の r は生文字列ではない', () {
      // ⚠ Dart では識別子の直後に文字列リテラルを書けないので、1 つ前が
      // 識別子文字なら `r` は名前の一部。
      expect(isRawStringStart("var'x'", 3), isFalse);
      expect(isRawStringStart("_r'x'", 2), isFalse);
    });

    test('r が付いていなければ生文字列ではない', () {
      expect(isRawStringStart("a = 'x'", 4), isFalse);
    });
  });

  group('⚠⚠ 歯があること: 生文字列の末尾の \\ で実コードが消える', () {
    /// ⚠ **同じ行に続きがある形。**[maskStrings] は 1 行の文字列を改行で
    /// 打ち切るので、被害は**その行の残り**に出る（実物の
    /// `if (text[i] == r'\') {` がまさにこれ）。
    const sameLine = "if (text[i] == r'\\') { launchUrl(uri); }";

    /// ⚠ **[maskComments] は改行で戻らない。**閉じ引用符を食べると、次の引用符
    /// まで「文字列の中」が続き、その間の**コメントを落とさなくなる**
    /// （コメント内のコード片を違反として数え始める）。
    final acrossLines = [
      "final sep = r'\\';",
      '// 落ちるべきコメント',
      'launchUrl(uri);',
    ].join('\n');

    test('直す前のマスキングでは同じ行の検出対象が消える（症状そのもの）', () {
      expect(
        naiveMaskStrings(sameLine),
        isNot(contains('launchUrl(')),
        reason: '比較相手が症状を再現していない。この検査の前提が壊れている',
      );
    });

    test('今のマスキングでは同じ行の検出対象が残る', () {
      expect(maskStrings(maskComments(sameLine)), contains('launchUrl('));
    });

    test('生文字列の後ろでもコメントは落ちる', () {
      expect(maskComments(acrossLines), isNot(contains('落ちるべきコメント')));
      expect(maskComments(acrossLines), contains('launchUrl('));
    });

    test('通常の文字列のエスケープは今も飛ばす', () {
      // ⚠ 生文字列対応で壊していないこと。`'\''` は 1 文字の `'`。
      expect(
        maskStrings("a = '\\'' ; launchUrl(uri);"),
        contains('launchUrl('),
      );
    });

    test('生文字列の中身は今も潰す', () {
      expect(maskStrings("a = r'secret';"), isNot(contains('secret')));
    });
  });

  group('走査が空振りしていない（実物で確かめる）', () {
    const path = 'lib/src/service/settings_backup.dart';

    test('実物に生文字列の末尾 \\ が残っている', () {
      // ⚠ この形が無くなったら、上の検査は合成だけの話になる。
      expect(
        File(path).readAsStringSync(),
        contains("== r'\\')"),
        reason: '$path の書き方が変わった。まだ守る値があるかを見直す',
      );
    });

    test('実物でも、生文字列より後ろの実コードが残る', () {
      final masked = maskStrings(maskComments(File(path).readAsStringSync()));
      // `r'\'` の 10 行ほど後ろにある実コード。直す前はここが空白へ潰れていた。
      expect(
        masked,
        contains('return i + 1;'),
        reason: 'マスキングが生文字列でずれている。以降の違反が検査から消える',
      );
    });

    test('生文字列の末尾 \\ を持つソースは他にもある', () {
      // ⚠ 1 ファイルだけの話にしない（テスト側の個別実装にも同じ形がある）。
      final holders = [
        for (final file in sourceFiles('lib'))
          if (file.readAsStringSync().contains("r'\\'")) file.path,
      ];
      expect(holders, isNotEmpty);
    });
  });
}

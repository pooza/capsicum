import 'package:capsicum/src/ui/util/antenna_text.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1052: アンテナの条件と入力欄の文字の行き来（Misskey Web と同じ規則）。
void main() {
  test('改行が「または」、半角スペースが「かつ」', () {
    expect(antennaKeywordsFromText('プリキュア 実況\nprecure'), [
      ['プリキュア', '実況'],
      ['precure'],
    ]);
  });

  test('⚠ 全角スペースでは区切らない（Web で作った 1 語を割らない）', () {
    expect(antennaKeywordsFromText('プリキュア　実況'), [
      ['プリキュア　実況'],
    ]);
  });

  test('空の行・連続した空白・前後の空白は落とす', () {
    expect(antennaKeywordsFromText('  a  b \n\n\n c '), [
      ['a', 'b'],
      ['c'],
    ]);
    expect(antennaKeywordsFromText('   \n  '), isEmpty);
  });

  test('文字へ戻して読み直すと同じ条件になる', () {
    const keywords = [
      ['プリキュア', '実況'],
      ['precure'],
    ];

    expect(antennaKeywordsFromText(antennaKeywordsToText(keywords)), keywords);
  });

  test('ユーザーは 1 行に 1 人。空の行は落とす', () {
    expect(antennaUsersFromText('@a\n\n @b@example.com \n'), [
      '@a',
      '@b@example.com',
    ]);
    expect(antennaUsersToText(['@a', '@b']), '@a\n@b');
  });
}

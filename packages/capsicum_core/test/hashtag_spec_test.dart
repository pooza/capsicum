import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';

/// #1159: `+` を含むタグと AND 指定の区別。
///
/// ⚠⚠ **Misskey のハッシュタグは `+` を含みうる。**`#c++` はダイスキーに実在する
/// （2026-09-19 実測）。capsicum は AND 指定を `+` 連結の 1 本の文字列で表して
/// いるので、エスケープしないと `c` と空タグへ割れて別物になる。
void main() {
  group('spec の組み立てと分解', () {
    test('単独のタグはそのまま', () {
      expect(hashtagSpecFromTag('precure_fun'), 'precure_fun');
      expect(hashtagSpecTags('precure_fun'), ['precure_fun']);
    });

    test('AND 指定は `+` で連結する', () {
      expect(
        hashtagSpecFromTags(['delmulin', 'capsicum']),
        'delmulin+capsicum',
      );
      expect(hashtagSpecTags('delmulin+capsicum'), ['delmulin', 'capsicum']);
    });

    test('⚠⚠ `+` を含むタグはエスケープされ、1 つのタグとして読み戻せる', () {
      final spec = hashtagSpecFromTag('c++');
      expect(spec, 'c%2B%2B', reason: '区切りの `+` と区別できる形にする');
      expect(hashtagSpecTags(spec), [
        'c++',
      ], reason: '⚠ ここが割れると、そのタグの TL にならない');
    });

    test('`+` を含むタグを AND 条件に混ぜても割れない', () {
      final spec = hashtagSpecFromTags(['c++', 'programming']);
      expect(hashtagSpecTags(spec), ['c++', 'programming']);
    });

    test('`%` もエスケープして読み戻せる（`%2B` と衝突させない）', () {
      final spec = hashtagSpecFromTag('100%');
      expect(spec, '100%25');
      expect(hashtagSpecTags(spec), ['100%']);

      // ⚠ `%2B` という文字列を含むタグも、エスケープを通れば区別できる。
      final tricky = hashtagSpecFromTag('a%2Bb');
      expect(hashtagSpecTags(tricky), ['a%2Bb']);
    });

    test('空のタグは落とす（`+` だけ・連続した `+`）', () {
      expect(hashtagSpecTags('a++b'), ['a', 'b']);
      expect(hashtagSpecTags('+'), isEmpty);
      expect(hashtagSpecFromTags(['a', '', 'b']), 'a+b');
    });
  });

  group('⚠ 既存の保存値（エスケープ導入前）がそのまま読める', () {
    test('単独のタグ', () {
      expect(hashtagSpecTags('precure_fun'), ['precure_fun']);
    });

    test('AND 指定', () {
      expect(hashtagSpecTags('nitiasa+precure'), ['nitiasa', 'precure']);
    });

    test('⚠ 素の `%` を含む保存値も壊れない（`%25` 以外は触らない）', () {
      expect(hashtagSpecTags('100%off'), ['100%off']);
    });
  });

  group('HashtagTab', () {
    test('⚠⚠ HashtagTab.single はタグ名をエスケープして保持する', () {
      final tab = HashtagTab.single('c++');
      expect(tab.tag, 'c%2B%2B');
      expect(tab.tags, ['c++']);
      expect(tab.toKey(), 'hashtag:c%2B%2B');
    });

    test('保存形式から読み戻すと同じタブになる', () {
      final tab = HashtagTab.single('c++');
      expect(TabType.fromKey(tab.toKey()), tab);
      expect((TabType.fromKey(tab.toKey())! as HashtagTab).tags, ['c++']);
    });

    test('AND 指定のタブは複数のタグを返す', () {
      const tab = HashtagTab('delmulin+capsicum');
      expect(tab.tags, ['delmulin', 'capsicum']);
    });
  });
}

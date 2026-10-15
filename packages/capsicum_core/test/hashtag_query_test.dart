import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';

/// #1209: タグ TL の条件（すべて含む / いずれかを含む / 含まない）。
void main() {
  group('spec の読み書き', () {
    test('⚠⚠ 以前からの spec は、そのまま「すべて含む」として読める（移行なし）', () {
      expect(HashtagQuery.parse('precure').all, ['precure']);
      expect(HashtagQuery.parse('nitiasa+precure').all, ['nitiasa', 'precure']);
      expect(HashtagQuery.parse('c%2B%2B').all, ['c++']);
      for (final legacy in ['precure', 'nitiasa+precure', 'c%2B%2B']) {
        final query = HashtagQuery.parse(legacy);
        expect(query.any, isEmpty);
        expect(query.none, isEmpty);
        expect(query.toSpec(), legacy, reason: '書き戻しても同じ spec（重複の判定が割れない）');
      }
    });

    test('3 つの節を往復する', () {
      final query = HashtagQuery(all: ['a'], any: ['b', 'c'], none: ['d', 'e']);
      expect(query.toSpec(), 'a?b+c!d+e');
      final parsed = HashtagQuery.parse('a?b+c!d+e');
      expect(parsed.all, ['a']);
      expect(parsed.any, ['b', 'c']);
      expect(parsed.none, ['d', 'e']);
      expect(parsed, query);
    });

    test('「いずれか」だけ・除外つき', () {
      expect(HashtagQuery(any: ['a', 'b']).toSpec(), '?a+b');
      expect(HashtagQuery.parse('?a+b').any, ['a', 'b']);
      expect(HashtagQuery(all: ['a'], none: ['x']).toSpec(), 'a!x');
      expect(HashtagQuery.parse('a!x').none, ['x']);
    });

    test('⚠⚠ 「いずれか」が 1 つだけなら「すべて含む」へ寄せる（同じ条件を 2 通りに書かせない）', () {
      final query = HashtagQuery(any: ['a']);
      expect(query.all, ['a']);
      expect(query.any, isEmpty);
      expect(query.toSpec(), 'a');
      expect(HashtagQuery.parse('?a').toSpec(), 'a');
      expect(HashtagQuery.parse('b?a').toSpec(), 'b+a');
    });

    test('⚠ 区切りの文字を含むタグはエスケープされ、節として読まれない', () {
      final query = HashtagQuery(all: ['what?'], any: ['c++', 'wow!']);
      final spec = query.toSpec();
      expect(spec, 'what%3F?c%2B%2B+wow%21');
      final parsed = HashtagQuery.parse(spec);
      expect(parsed.all, ['what?']);
      expect(parsed.any, ['c++', 'wow!']);
      expect(parsed.none, isEmpty);
    });

    test('空のタグと重複（大小違いを含む）は落とす', () {
      final query = HashtagQuery(all: ['a', '', 'A', 'b']);
      expect(query.all, ['a', 'b']);
    });

    test('⚠ 除外だけの条件は空として扱う（TL にならない）', () {
      expect(HashtagQuery(none: ['x']).isEmpty, isTrue);
      expect(HashtagQuery.parse('!x').isEmpty, isTrue);
      expect(HashtagQuery.parse('').isEmpty, isTrue);
      expect(HashtagQuery(all: ['a'], none: ['x']).isEmpty, isFalse);
    });
  });

  group('singleTag（タグのフォロー・タグ 1 つのストリーム）', () {
    test('タグ 1 つだけなら返す', () {
      expect(HashtagQuery.parse('precure').singleTag, 'precure');
      expect(HashtagQuery.parse('c%2B%2B').singleTag, 'c++');
    });

    test('⚠ AND・OR・除外のどれかがあれば null', () {
      expect(HashtagQuery.parse('a+b').singleTag, isNull);
      expect(HashtagQuery.parse('?a+b').singleTag, isNull);
      expect(HashtagQuery.parse('a!x').singleTag, isNull);
    });
  });

  group('サーバーへ送る形', () {
    test('Mastodon: 「すべて含む」だけなら、先頭がパスで残りが all[]（今までどおり）', () {
      final request = HashtagQuery.parse('a+b+c').tagFeedRequest!;
      expect(request.primary, 'a');
      expect(request.all, ['b', 'c']);
      expect(request.any, isEmpty);
    });

    test('Mastodon: 「いずれか」があれば、その先頭がパスで残りが any[]', () {
      // パスのタグと any[] が OR、all[] が AND になる（サーバーの TagFeed）。
      final request = HashtagQuery.parse('x?a+b+c').tagFeedRequest!;
      expect(request.primary, 'a');
      expect(request.any, ['b', 'c']);
      expect(request.all, ['x']);
    });

    test('Misskey: 外側が OR・内側が AND', () {
      expect(HashtagQuery.parse('a+b').orOfAnds, [
        ['a', 'b'],
      ]);
      expect(HashtagQuery.parse('?a+b').orOfAnds, [
        ['a'],
        ['b'],
      ]);
      expect(HashtagQuery.parse('x?a+b!z').orOfAnds, [
        ['a', 'x'],
        ['b', 'x'],
      ]);
    });

    test('含む側が無ければ、どちらも送る形にならない', () {
      expect(HashtagQuery.parse('!x').tagFeedRequest, isNull);
      expect(HashtagQuery.parse('!x').orOfAnds, isEmpty);
    });
  });

  group('投稿のタグとの突き合わせ', () {
    final query = HashtagQuery.parse('x?a+b!z');

    test('条件に合う', () {
      expect(query.matches(['x', 'a']), isTrue);
      expect(query.matches(['X', 'B', 'other']), isTrue, reason: '大小は区別しない');
    });

    test('「すべて含む」が欠けている / 「いずれか」が 1 つも無い', () {
      expect(query.matches(['a']), isFalse);
      expect(query.matches(['x']), isFalse);
    });

    test('除外のタグがあれば合わない', () {
      expect(query.matches(['x', 'a', 'Z']), isFalse);
      expect(query.excludes(['x', 'a', 'Z']), isTrue);
      expect(query.excludes(['x', 'a']), isFalse);
    });
  });

  // #1283: Mastodon は `all[]` のうちサーバーに実在しないタグを黙って落とすので、
  // 返ってきた一覧を端末側で確かめ直す。
  group('「すべて含む」を欠く投稿の検出（サーバーの結果の確かめ直し）', () {
    test('⚠⚠ 「すべて含む」のタグを 1 つでも欠けば、欠いている', () {
      final query = HashtagQuery.parse('precure+nitiasa');
      expect(query.lacksRequired(['precure']), isTrue);
      expect(query.lacksRequired(['precure', 'nitiasa']), isFalse);
      expect(query.lacksRequired(['PreCure', 'NITIASA', 'x']), isFalse);
    });

    test('ひらがな・カタカナ・漢字のタグも確かめる', () {
      final query = HashtagQuery.parse('プリキュア+実況');
      expect(query.lacksRequired(['プリキュア']), isTrue);
      expect(query.lacksRequired(['プリキュア', '実況']), isFalse);
      expect(HashtagQuery.parse('a+ひらがな').lacksRequired(['a']), isTrue);
      expect(HashtagQuery.parse('a+スーパー').lacksRequired(['a']), isTrue);
    });

    // サーバーはタグを正規化して比べる。端末側の素朴な比較で「欠いている」と
    // 読み違えると、合っている投稿が全部落ちて TL が空になる。
    test('⚠⚠ 正規化で形が変わりうるタグは確かめない（サーバーの結果を信じる）', () {
      // 全角英数（NFKC で半角になる）。サーバーの tags は `abc` で返る。
      expect(HashtagQuery.parse('a+ＡＢＣ').lacksRequired(['a', 'abc']), isFalse);
      // 半角カナ（NFKC で全角になる）。
      expect(
        HashtagQuery.parse('a+ﾌﾟﾘｷｭｱ').lacksRequired(['a', 'プリキュア']),
        isFalse,
      );
      // アクセント付き（サーバーは外して比べる）。
      expect(
        HashtagQuery.parse('a+café').lacksRequired(['a', 'cafe']),
        isFalse,
      );
      // ⚠ 確かめないタグが混ざっていても、確かめられるタグは見る。
      expect(
        HashtagQuery.parse('a+b+café').lacksRequired(['a', 'cafe']),
        isTrue,
      );
    });

    // ⚠⚠ いちばん大事な固定。タグ 1 つの TL（プリセットのデフォルトハッシュタグ）
    // は、投稿のタグがどう見えていても 1 件も落とさない。
    test('⚠⚠ タグ 1 つだけの TL では、何も欠いていない', () {
      expect(
        HashtagQuery.parse('precure_fun').lacksRequired(const []),
        isFalse,
      );
      expect(HashtagQuery.parse('a!z').lacksRequired(const []), isFalse);
    });

    // パスに載せる 1 つ目のタグは、実在しなければサーバーが空を返す（黙って
    // 外れない）ので確かめない。
    test('パスに載せる 1 つ目のタグは確かめない', () {
      expect(HashtagQuery.parse('a+b').lacksRequired(['b']), isFalse);
      // 「いずれか」があるときは、その先頭がパスに載り、「すべて含む」は
      // 全部 all[] で送る。
      expect(HashtagQuery.parse('x?a+b').lacksRequired(['a']), isTrue);
    });

    test('「いずれか」と除外は、ここでは見ない', () {
      final query = HashtagQuery.parse('x?a+b!z');
      expect(query.lacksRequired(['x']), isFalse, reason: 'いずれかは欠いていてよい');
      expect(query.lacksRequired(['x', 'z']), isFalse, reason: '除外は別に見る');
      expect(query.lacksRequired(['a']), isTrue);
    });

    test('「すべて含む」が空なら、何も欠いていない', () {
      expect(HashtagQuery.parse('?a+b').lacksRequired(const []), isFalse);
    });
  });

  test('この TL から投稿するときに付けるタグは、「すべて含む」の全部と「いずれか」の先頭', () {
    expect(HashtagQuery.parse('a+b').tagsToPost, ['a', 'b']);
    expect(HashtagQuery.parse('x?a+b!z').tagsToPost, ['x', 'a']);
  });
}

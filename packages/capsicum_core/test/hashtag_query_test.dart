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

  test('この TL から投稿するときに付けるタグは、「すべて含む」の全部と「いずれか」の先頭', () {
    expect(HashtagQuery.parse('a+b').tagsToPost, ['a', 'b']);
    expect(HashtagQuery.parse('x?a+b!z').tagsToPost, ['x', 'a']);
  });

  test('hashtagSpecTags は含む側のタグだけを返す', () {
    expect(hashtagSpecTags('x?a+b!z'), ['x', 'a', 'b']);
  });
}

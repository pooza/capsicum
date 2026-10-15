import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1288: Misskey の `mutedWords` / `hardMutedWords` は `(string[] | string)[]`。
/// 正規表現の行は配列に入らない素の文字列で返る。
void main() {
  MisskeyUser parse(Map<String, dynamic> extra) =>
      MisskeyUser.fromJson({'id': 'me', 'username': 'pooza', ...extra});

  test('⚠⚠ 正規表現の行（素の文字列）が混ざっていても読める', () {
    final user = parse({
      'mutedWords': [
        ['ダイ', 'ポップ'],
        '/アバン/i',
      ],
      'hardMutedWords': ['/ハドラー/'],
    });

    expect(user.mutedWords, [
      ['ダイ', 'ポップ'],
      '/アバン/i',
    ]);
    expect(user.mutedWords!.first, isA<List<String>>());
    expect(user.hardMutedWords, ['/ハドラー/']);
  });

  test('⚠ 形の合わない要素は捨てる（1 行の崩れで全体を落とさない）', () {
    final user = parse({
      'mutedWords': [
        42,
        null,
        {'word': 'x'},
        ['ダイ', 1, 'ポップ'],
        '/アバン/',
      ],
    });

    expect(user.mutedWords, [
      ['ダイ', 'ポップ'],
      '/アバン/',
    ]);
  });

  test('無い・配列でないときは null', () {
    expect(parse({}).mutedWords, isNull);
    expect(parse({'mutedWords': 'x'}).mutedWords, isNull);
  });
}

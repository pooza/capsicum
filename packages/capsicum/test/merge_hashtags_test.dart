import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1056: サーバーの `tags` を正本に、表示の形は本文のパースから取る。
///
/// ⚠⚠ **サーバーの `tags` をそのまま出すと見た目が劣化する。**2026-09-26 の実測
/// （230 投稿 / 861 タグ / 27 ホスト）では **7 割の投稿で本文と大小が違った**
/// （`github` / `GitHub`）。両 SNS の Web UI も本文の形で出す。
Post _post(
  String content, {
  List<String> tags = const [],
  bool isHtml = false,
}) => Post(
  id: 'p1',
  postedAt: DateTime.utc(2026, 1, 1),
  author: User(id: 'u1', username: 'u1'),
  content: content,
  isHtml: isHtml,
  tags: tags,
);

void main() {
  group('mergeHashtags', () {
    test('⚠ サーバーが返していなければ本文のパースをそのまま使う', () {
      expect(mergeHashtags(const [], const ['GitHub', 'Spotify']), [
        'GitHub',
        'Spotify',
      ]);
    });

    test('⚠⚠ 大小が違っても本文の形を出す（サーバーは小文字へ正規化している）', () {
      expect(
        mergeHashtags(const ['github', 'spotify'], const ['GitHub', 'Spotify']),
        ['GitHub', 'Spotify'],
      );
    });

    test('⚠ 本文に無いタグはサーバーの形で後ろへ足す（今まで出ていなかったぶん）', () {
      expect(mergeHashtags(const ['github', 'hidden'], const ['GitHub']), [
        'GitHub',
        'hidden',
      ]);
    });

    test('並びは本文の出現順が先', () {
      expect(mergeHashtags(const ['b', 'a'], const ['A', 'B']), ['A', 'B']);
    });

    test('⚠ サーバーが認めていないタグは落とす（コードブロック内の誤検出等）', () {
      expect(mergeHashtags(const ['real'], const ['real', 'bogus']), ['real']);
    });

    test('重複を足さない', () {
      expect(mergeHashtags(const ['a'], const ['A', 'a']), ['A']);
    });

    test('どちらも空なら空', () {
      expect(mergeHashtags(const [], const []), isEmpty);
    });

    test('本文が空でもサーバーのタグは拾う', () {
      expect(mergeHashtags(const ['a', 'b'], const []), ['a', 'b']);
    });
  });

  group('postHashtags', () {
    test('MFM の本文とサーバーの tags を合流させる', () {
      final post = _post(
        '見てます #GitHub と #Spotify',
        tags: const ['github', 'spotify'],
      );

      expect(postHashtags(post), ['GitHub', 'Spotify']);
    });

    test('HTML の本文でも同じ', () {
      final post = _post(
        '<p>見てます <a href="https://x/tags/GitHub" class="hashtag">#<span>GitHub</span></a></p>',
        tags: const ['github'],
        isHtml: true,
      );

      expect(postHashtags(post), ['GitHub']);
    });

    test('⚠⚠ 本文が null でもサーバーのタグを返す（添付だけの投稿）', () {
      final post = Post(
        id: 'p1',
        postedAt: DateTime.utc(2026, 1, 1),
        author: User(id: 'u1', username: 'u1'),
        tags: const ['photo'],
      );

      expect(postHashtags(post), ['photo']);
    });

    test('⚠ サーバーが tags を返さない投稿は従来どおり本文から拾う', () {
      final post = _post('#precure_fun 見てます');

      expect(postHashtags(post), ['precure_fun']);
    });
  });

  group('Post.copyWith は tags を落とさない', () {
    test('⚠ enrich（猫耳等）で作り直してもタグが残る', () {
      final post = _post('#a', tags: const ['a']);

      final enriched = post.copyWith(
        author: User(id: 'u1', username: 'u1', isCat: true),
      );

      expect(enriched.tags, ['a']);
    });
  });
}

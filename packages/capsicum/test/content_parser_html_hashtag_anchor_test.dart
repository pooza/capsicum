import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1151: Mastodon の投稿（HTML）のハッシュタグは、**送信元が決めた範囲のまま**
/// 受け取る。
///
/// 表示する側は、タグを決める立場ではない。Mastodon の API が返す `content` には、
/// そのタグを決めたサーバーの判定が `<a>` として焼き込まれている（ローカル投稿は
/// 自サーバーの判定、リモート投稿は送信元の HTML そのまま）。以前はこの `<a>` を
/// 素の `#tag` に戻して自前の判定（#566）で読み直していたので、送信元とずれた。
///
/// ⚠ 期待値は「送信元の HTML がどうなっているか」から決めている（自前の判定が
/// どう返すか、ではない）。
void main() {
  String anchor(String label, {String? href, bool mastodon = true}) =>
      '<a href="${href ?? 'https://mstdn.example/tags/x'}"'
      '${mastodon ? ' class="mention hashtag" rel="tag"' : ''}>'
      '${mastodon ? '#<span>${label.substring(1)}</span>' : label}</a>';

  List<String> tags(String html) => parseHtmlForTesting(html).hashtags;

  group('送信元がリンクにした範囲を、そのままタグにする', () {
    test('⚠⚠ 中黒を含むタグを途中で切らない', () {
      // Mastodon 4.1 以降は中黒をタグに含める。自前の判定はここで切っていた。
      expect(tags('<p>${anchor('#プリキュア・オールスターズ')} を見た</p>'), ['プリキュア・オールスターズ']);
    });

    test('⚠ 自前の判定なら弾く形（数字だけ）でも、送信元がタグにしたならタグ', () {
      expect(tags('<p>${anchor('#2026')}</p>'), ['2026']);
    });

    test('⚠ 直前が英数字でも、送信元がタグにしたならタグ', () {
      expect(tags('<p>abc${anchor('#tag')}</p>'), ['tag']);
    });

    test('class の無い形（Misskey 由来）も同じ', () {
      expect(tags('<p>${anchor('#ねこ-かわいい', mastodon: false)}</p>'), [
        'ねこ-かわいい',
      ]);
    });

    test('複数あれば出現順', () {
      expect(tags('<p>${anchor('#a1')} と ${anchor('#b・c')}</p>'), [
        'a1',
        'b・c',
      ]);
    });
  });

  group('送信元がリンクにしなかった # は、タグにしない', () {
    test('⚠⚠ 裸の #tag', () {
      expect(tags('<p>これは #タグ ではない</p>'), isEmpty);
    });

    test('⚠ リンクになったタグと混ざっていても、裸のほうは拾わない', () {
      expect(tags('<p>${anchor('#本物')} と #偽物</p>'), ['本物']);
    });

    test('前提: 素通しになった # は文字として残る（消えない）', () {
      final parsed = parseHtmlForTesting('<p>これは #タグ ではない</p>');
      expect(parsed.hashtags, isEmpty);
      expect(parsed.hasRawTag, isFalse);
      expect(parsed.plainText, contains('#タグ'));
    });
  });

  group('引用ブロックの中', () {
    test('⚠ 中のタグも、送信元の範囲のまま拾う', () {
      // 引用ブロックの変換は中の HTML タグを落とす。先に拾っておかないと、
      // 裸の `#tag` になってタグでなくなる。
      expect(tags('<blockquote><p>${anchor('#引用・の中')}</p></blockquote>'), [
        '引用・の中',
      ]);
    });
  });

  group('ハッシュタグでない <a> は従来どおり', () {
    test('ラベルが # で始まっても、空白を含むならリンク (#750)', () {
      final parsed = parseHtmlForTesting(
        '<p><a href="https://example.com/a">#1 の 記事</a></p>',
      );
      expect(parsed.hashtags, isEmpty);
      expect(parsed.links.single.url, 'https://example.com/a');
    });

    test('ふつうのリンクはリンクのまま', () {
      final parsed = parseHtmlForTesting(
        '<p><a href="https://example.com/a">記事</a> ${anchor('#tag')}</p>',
      );
      expect(parsed.links.single.text, '記事');
      expect(parsed.hashtags, ['tag']);
    });
  });

  group('Misskey の投稿（MFM）は変えていない', () {
    test('裸の #tag は従来どおりタグ', () {
      expect(parseHashtagsForTesting('本文 #タグ 続き'), ['タグ']);
    });
  });

  group('全ハッシュタグのコピー (#794) にもそのまま効く', () {
    test('送信元の範囲で取り出す', () {
      expect(
        extractHashtags('<p>${anchor('#プリキュア・オールスターズ')} #裸</p>', isHtml: true),
        ['プリキュア・オールスターズ'],
      );
    });
  });
}

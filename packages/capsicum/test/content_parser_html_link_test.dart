import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('content_parser HTML <a> — Misskey 連合ノートのリンク露出 (#595)', () {
    test('Misskey 由来の <a href> リンクが MFM リンクとして解釈される', () {
      // tiramiss/Misskey は <p> ラップせず <a> を素で federate する。
      final r = parseHtmlForTesting(
        '🎁 <b>NEW RELEASE</b>: '
        '<a href="https://github.com/misskey-dev/misskey/releases/tag/2026.5.4" '
        'rel="nofollow noopener" target="_blank">2026.5.4</a> is out.',
      );
      expect(r.hasRawTag, isFalse, reason: '生の <a タグが露出してはいけない');
      expect(r.links, [
        (
          text: '2026.5.4',
          url: 'https://github.com/misskey-dev/misskey/releases/tag/2026.5.4',
        ),
      ]);
    });

    test('ハッシュタグ anchor は hashtag ノードに戻る（プレーンリンク化しない）', () {
      final r = parseHtmlForTesting(
        '<a href="https://example.com/tags/capsicum" '
        'class="mention hashtag" rel="tag">#<span>capsicum</span></a>',
      );
      expect(r.links, isEmpty);
      expect(r.hashtags, ['capsicum']);
    });

    test('メンション anchor は素のテキストに戻る（プレーンリンク化しない）', () {
      final r = parseHtmlForTesting(
        '<a href="https://example.com/@bob" class="u-url mention">'
        '@<span>bob</span></a>',
      );
      expect(r.links, isEmpty);
      expect(r.hasRawTag, isFalse);
    });

    test('ラベルが URL と同一の anchor は url ノードになる', () {
      final r = parseHtmlForTesting(
        '<a href="https://example.com/" rel="nofollow">'
        'https://example.com/</a>',
      );
      expect(r.links, isEmpty);
      expect(r.urls, ['https://example.com/']);
    });

    test('通常の Mastodon 段落リンク（span 入り・テキスト=URL）も維持される', () {
      final r = parseHtmlForTesting(
        '<p>see <a href="https://example.com/page" rel="nofollow noopener" '
        'target="_blank"><span class="invisible">https://</span>'
        '<span class="ellipsis">example.com/page</span></a></p>',
      );
      expect(r.hasRawTag, isFalse);
      expect(r.urls, ['https://example.com/page']);
    });
  });
}

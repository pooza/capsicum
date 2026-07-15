import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractHashtags — 本文からのハッシュタグ抽出 (#794)', () {
    test('MFM 本文から出現順で抽出（# は含めない）', () {
      expect(extractHashtags('楽しい #capsicum の #delmulin 実況', isHtml: false), [
        'capsicum',
        'delmulin',
      ]);
    });

    test('重複タグは除去し初出順を保つ', () {
      expect(extractHashtags('#a テスト #b また #a', isHtml: false), ['a', 'b']);
    });

    test('ハッシュタグが無ければ空', () {
      expect(extractHashtags('ただの本文です', isHtml: false), isEmpty);
      expect(extractHashtags('', isHtml: false), isEmpty);
    });

    test('Mastodon HTML の anchor ハッシュタグも抽出できる', () {
      const html =
          '<p>実況 '
          '<a href="https://mstdn.b-shock.org/tags/capsicum" '
          'class="mention hashtag" rel="tag">#<span>capsicum</span></a> '
          'です</p>';
      expect(extractHashtags(html, isHtml: true), ['capsicum']);
    });

    test('CJK タグも抽出できる', () {
      expect(extractHashtags('#日記2026 を書いた', isHtml: false), ['日記2026']);
    });
  });
}

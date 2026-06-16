import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('stripHtmlRestoringMentions — redraft メンション host 復元 (#703)', () {
    const localHost = 'mstdn.b-shock.org';

    test('リモートメンションは @user@host に展開される', () {
      // Mastodon の mention anchor は可視テキストが @user のみ、host は href 側。
      final r = stripHtmlRestoringMentions(
        '<p><a href="https://example.com/@alice" class="u-url mention">'
        '@<span>alice</span></a> hello</p>',
        localHost: localHost,
      );
      expect(r, '@alice@example.com hello');
    });

    test('ローカルメンションは @user のまま（host を付けない）', () {
      final r = stripHtmlRestoringMentions(
        '<p><a href="https://$localHost/@bob" class="u-url mention">'
        '@<span>bob</span></a> hi</p>',
        localHost: localHost,
      );
      expect(r, '@bob hi');
    });

    test('複数メンション（ローカル + リモート混在）をそれぞれ正しく扱う', () {
      final r = stripHtmlRestoringMentions(
        '<p><a href="https://$localHost/@bob" class="u-url mention">'
        '@<span>bob</span></a> '
        '<a href="https://remote.example/@carol" class="u-url mention">'
        '@<span>carol</span></a></p>',
        localHost: localHost,
      );
      expect(r, '@bob @carol@remote.example');
    });

    test('メンション以外の anchor（通常リンク）は可視ラベルに平文化される', () {
      final r = stripHtmlRestoringMentions(
        '<p>see <a href="https://example.com/page" rel="nofollow">'
        'the page</a></p>',
        localHost: localHost,
      );
      expect(r, 'see the page');
    });

    test('href が空 / 解析不能でもラベルは保持する', () {
      final r = stripHtmlRestoringMentions(
        '<p><a href="" class="u-url mention">@<span>dave</span></a></p>',
        localHost: localHost,
      );
      expect(r, '@dave');
    });

    test('既に @user@host 形式のメンションは二重展開しない', () {
      final r = stripHtmlRestoringMentions(
        '<p><a href="https://remote.example/@erin" class="u-url mention">'
        '@<span>erin@remote.example</span></a></p>',
        localHost: localHost,
      );
      expect(r, '@erin@remote.example');
    });
  });
}

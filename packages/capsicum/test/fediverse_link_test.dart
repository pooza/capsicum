import 'package:capsicum/src/ui/util/fediverse_link.dart';
import 'package:flutter_test/flutter_test.dart';

/// #820 の resolve ガード。fediverse の投稿/アカウント URL だけを resolve 対象と
/// 判定し、外部サイト（Google Form 等）は弾く（＝そのままブラウザ）ことを検証する。
void main() {
  bool check(String url) => looksLikeFediverseUrl(Uri.parse(url));

  group('looksLikeFediverseUrl (#820)', () {
    test('Mastodon アカウント /@user → true', () {
      expect(check('https://mstdn.example/@alice'), isTrue);
    });

    test('Mastodon 投稿 /@user/123 → true', () {
      expect(check('https://mstdn.example/@alice/109876543210'), isTrue);
    });

    test('Mastodon /users/x/statuses/y → true', () {
      expect(check('https://mstdn.example/users/alice/statuses/123'), isTrue);
    });

    test('Misskey ノート /notes/xxx → true', () {
      expect(check('https://misskey.example/notes/9abcxyz'), isTrue);
    });

    test('bare な /users/foo（github 等）→ false（statuses を伴わない・#838）', () {
      expect(check('https://github.com/users/octocat'), isFalse);
    });

    test('他サイトの /notes/x（短い id）→ false（誤検知回避・#838）', () {
      expect(check('https://example.com/notes/x'), isFalse);
    });

    test('外部サイトのフォーム → false（resolve せずブラウザ）', () {
      expect(
        check('https://docs.google.com/forms/d/e/abcXYZ/viewform'),
        isFalse,
      );
    });

    test('素の外部サイト → false', () {
      expect(check('https://example.com/blog/2026/07'), isFalse);
    });

    test('ルートのみ → false', () {
      expect(check('https://mstdn.example/'), isFalse);
    });

    test('非 http スキーム → false', () {
      expect(check('mailto:alice@example.com'), isFalse);
    });

    test('ホストなし → false', () {
      expect(check('/@alice'), isFalse);
    });
  });

  /// #830 の Play リンク振り分け。自ホストの `/play/<id>` だけネイティブの
  /// `/play` 画面で開き、他ホストは null（＝ブラウザ等へフォールバック）。
  group('misskeyPlayIdOnHost (#830)', () {
    String? play(String url, String? selfHost) =>
        misskeyPlayIdOnHost(Uri.parse(url), selfHost);

    test('自ホストの /play/<id> → id を返す', () {
      expect(
        play('https://misskey.example/play/9play01', 'misskey.example'),
        '9play01',
      );
    });

    test('末尾スラッシュがあっても id を返す', () {
      expect(
        play('https://misskey.example/play/9play01/', 'misskey.example'),
        '9play01',
      );
    });

    test('他ホストの /play/<id> → null（ブラウザへ）', () {
      expect(
        play('https://other.example/play/9play01', 'misskey.example'),
        isNull,
      );
    });

    test('selfHost が null → null', () {
      expect(play('https://misskey.example/play/9play01', null), isNull);
    });

    test('Play でない自ホスト URL → null', () {
      expect(
        play('https://misskey.example/notes/9abcxyz', 'misskey.example'),
        isNull,
      );
    });

    test('id を伴わない /play → null', () {
      expect(play('https://misskey.example/play', 'misskey.example'), isNull);
    });
  });
}

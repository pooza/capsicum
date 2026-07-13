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

    test('外部サイトのフォーム → false（resolve せずブラウザ）', () {
      expect(check('https://docs.google.com/forms/d/e/abcXYZ/viewform'), isFalse);
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
}

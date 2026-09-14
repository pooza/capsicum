import 'package:capsicum/src/util/post_text_length.dart';
import 'package:capsicum/src/util/text_length.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1034: 本文カウンタを Mastodon の数え方へ寄せる。
///
/// 正本は `pooza/mastodon` の `StatusLengthValidator`:
/// 書記素で数え、URL を 23 文字・メンションをドメイン部なしへ短縮し、
/// CW (`spoiler_text`) も同じ枠に含める。
///
/// ⚠ **entity 抽出は近似**（`twitter-text` の TLD 一覧までは持たない）。
/// このテストは「近似がどこまでを URL とみなすか」を固定するためにもある ——
/// 境界を変えたら、ここが落ちて意図の有無を問う。
void main() {
  int mastodon(String text, {String cw = ''}) =>
      postTextLength(PostLengthRule.shortenedGraphemes, text, cw: cw);
  int misskey(String text, {String cw = ''}) =>
      postTextLength(PostLengthRule.codePoints, text, cw: cw);

  group('Mastodon: URL は一律 23 文字', () {
    // ⚠⚠ **ここが実運用で一番効く。**実況で URL を 1 本貼るだけで 77 文字ぶん
    // 過大に数えていた（カウンタが赤いのにサーバーは通る）。
    test('⚠⚠ 長い URL は短くなる', () {
      const url =
          'https://example.com/watch?v=0123456789abcdef&list=0123456789abcdef';
      expect(url.length, 66, reason: '前提: 素の文字数');
      expect(mastodon(url), 23);
    });

    // ⚠ 逆向きにも効く。23 文字未満の URL は**長く**数えられる。
    test('⚠ 短い URL は長くなる', () {
      expect(mastodon('https://x.jp'), 23);
    });

    test('前後の文と混ぜても URL のぶんだけ置き換わる', () {
      // 'これ ' (3) + URL (23) + ' です' (3)
      expect(mastodon('これ https://example.com/a です'), 29);
    });

    test('複数本あればそれぞれ 23', () {
      expect(mastodon('https://example.com/a https://example.org/b'), 47);
    });

    // ⚠ **プロトコル無しは短縮しない。**バリデータが
    // `extract_url_without_protocol: false` と明示している。ここを欲張ると
    // 「〜.jp です」のような普通の日本語を 23 文字へ膨らませる。
    test('⚠ プロトコルが無ければ URL 扱いしない', () {
      expect(mastodon('example.com'), 11);
      expect(mastodon('あれは example.jp だよ'), 17);
    });

    // twitter-text の valid_domain は TLD を要求するので、ドットの無い host は
    // URL entity にならない。
    test('ドットの無いホストは短縮しない', () {
      const url = 'http://localhost:3000/x';
      expect(mastodon(url), url.length);
    });

    test('末尾の句読点は URL に含めない', () {
      // URL (23) + '。' (1)
      expect(mastodon('https://example.com/a。'), 24);
      // URL (23) + ', ' (2) + URL (23) + '.' (1)
      expect(mastodon('https://example.com/a, https://example.org/b.'), 49);
    });

    // ⚠ 括弧は釣り合いを見る。URL 自身が括弧を含む形（Wikipedia 等）がある。
    test('⚠ 閉じ括弧は釣り合っていれば URL の一部', () {
      // '(' (1) + URL (23) + ')' (1)
      expect(mastodon('(https://example.com/a)'), 25);
      // URL 内の (x) は釣り合っているので落とさない
      expect(mastodon('https://example.com/a_(x)'), 23);
    });
  });

  group('Mastodon: メンションはドメイン部を落とす', () {
    test('リモートのメンションは @user ぶん', () {
      expect(mastodon('@user@example.com'), 5);
    });

    test('ローカルのメンションは変わらない', () {
      expect(mastodon('@user'), 5);
    });

    test('前後の文と混ぜても置き換わる', () {
      // '@user' (5) + ' さん' (3)
      expect(mastodon('@user@example.com さん'), 8);
    });

    // ⚠⚠ **URL 中の `/@user` を二重に数えない。**Mastodon は
    // `remove_overlapping_entities` で重なりを落とし、先に始まる URL を残す。
    // ここを落とすと、プロフィール URL を貼ったときに数が狂う。
    test('⚠⚠ URL の中のメンションは URL 側に吸収される', () {
      // `/@user` は MENTION_RE の lookbehind（直前が `/`）で外れる。
      expect(mastodon('https://example.com/@user'), 23);
      // ⚠⚠ **こちらは lookbehind に掛からない。**`#` の直後なので mention
      // としても一致し、URL entity と**範囲が重なる**。開始位置の早い URL を
      // 残して捨てる（`remove_overlapping_entities`）ところ。
      expect(mastodon('https://example.com/a#@user'), 23);
    });

    test('メールアドレスのような形はメンションにしない', () {
      // 直前が word 文字なので MENTION_RE の lookbehind で外れる
      const text = 'user@example.com';
      expect(mastodon(text), text.length);
    });
  });

  group('Mastodon: 書記素で数える', () {
    // ⚠⚠ **コードポイントとの差が最大になる形。**家族絵文字は書記素 1・
    // コードポイント 7。サーバーは 1 と数えるので、コードポイントで数えると
    // **必要以上に赤くなる**。
    test('⚠⚠ ZWJ の合字は 1 文字', () {
      const family = '👨‍👩‍👧‍👦';
      expect(serverTextLength(family), 7, reason: '前提: コードポイントなら 7');
      expect(mastodon(family), 1);
    });

    test('国旗も 1 文字', () {
      expect(mastodon('🇯🇵'), 1);
    });

    test('結合文字は 1 文字', () {
      expect(mastodon('é'), 1, reason: 'e + U+0301 は書記素 1');
    });
  });

  group('Mastodon: CW も同じ枠で数える', () {
    // ⚠⚠ **こちらは危険側のズレ。**URL の件は「余計に赤くなる」だけだが、CW を
    // 数えないと**カウンタが緑のままサーバーが弾く**。
    // `combined_text = [spoiler_text, countable_text(text)].join`。
    test('⚠⚠ CW のぶんだけ増える', () {
      expect(mastodon('abc', cw: 'ネタバレ'), 7);
    });

    // ⚠ CW は `countable_text` を通らない。URL を書いても 23 にならない。
    test('⚠ CW の URL は短縮されない', () {
      const cw = 'https://example.com/a';
      expect(cw.length, 21);
      expect(mastodon('', cw: cw), 21);
    });
  });

  group('Misskey: コードポイントのまま', () {
    test('URL もメンションも短縮しない', () {
      const url = 'https://example.com/watch?v=0123456789abcdef';
      expect(misskey(url), url.length);
      expect(misskey('@user@example.com'), 17);
    });

    test('従来の数え方（serverTextLength）と一致する', () {
      for (final text in [
        'abc',
        'あいう',
        '👨‍👩‍👧‍👦',
        '🇯🇵',
        'https://example.com/a',
      ]) {
        expect(misskey(text), serverTextLength(text), reason: text);
      }
    });

    // ⚠ **CW は別枠**（`notes/create` は text 3000 / cw 500 を独立に見る）。
    // 渡されても本文の数には足さない。
    test('⚠ CW は数に入れない', () {
      expect(misskey('abc', cw: 'ネタバレ'), 3);
    });
  });

  group('composePostLength（投稿フォームが出す数）', () {
    int compose(
      PostLengthRule rule, {
      required String text,
      required bool cwEnabled,
      required String cw,
    }) => composePostLength(rule, text: text, cwEnabled: cwEnabled, cw: cw);

    // ⚠⚠ **CW を閉じても欄の中身は残る。**足してしまうと、送らない文字で
    // カウンタが増える（閉じているのに赤い）。
    test('⚠⚠ CW が無効なら欄の中身は数えない', () {
      expect(
        compose(
          PostLengthRule.shortenedGraphemes,
          text: 'abc',
          cwEnabled: false,
          cw: 'ネタバレ',
        ),
        3,
      );
    });

    test('CW が有効なら足す', () {
      expect(
        compose(
          PostLengthRule.shortenedGraphemes,
          text: 'abc',
          cwEnabled: true,
          cw: 'ネタバレ',
        ),
        7,
      );
    });

    // 送信側が trim するので、数える側も trim 後で揃える。
    test('CW の前後の空白は送らないので数えない', () {
      expect(
        compose(
          PostLengthRule.shortenedGraphemes,
          text: '',
          cwEnabled: true,
          cw: '  ネタバレ  ',
        ),
        4,
      );
    });

    test('Misskey では CW が有効でも本文だけ', () {
      expect(
        compose(
          PostLengthRule.codePoints,
          text: 'abc',
          cwEnabled: true,
          cw: 'ネタバレ',
        ),
        3,
      );
    });
  });

  group('countableText（置き換え後の文字列）', () {
    test('URL は x 23 個へ', () {
      expect(countableText('https://example.com/a'), 'x' * 23);
      expect(kUrlPlaceholderLength, 23);
    });

    test('メンションはドメイン部が落ちる', () {
      expect(countableText('@user@example.com'), '@user');
    });

    test('entity が無ければそのまま', () {
      expect(countableText('ふつうの本文'), 'ふつうの本文');
      expect(countableText(''), '');
    });

    test('混在しても順番が崩れない', () {
      expect(
        countableText('@a@b.com と https://example.com/x と @c'),
        '@a と ${'x' * 23} と @c',
      );
    });
  });
}

import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('content_parser hashtag — Mastodon 仕様への寄せ (#566)', () {
    test('#26「夏だ！…」を視聴 — 数字のみ + 全角句読点で停止し非ハッシュタグ', () {
      final input = '#26「夏だ！海だ！キラパティ漂流記！」を視聴。';
      expect(parseHashtagsForTesting(input), isEmpty);
    });

    test('#日記2026 — 英数 + CJK letter の混合はタグ成立', () {
      expect(parseHashtagsForTesting('#日記2026'), ['日記2026']);
    });

    test('URL/path#section — 直前が word char (h, /) なら非ハッシュタグ', () {
      expect(
        parseHashtagsForTesting('https://example.com/path#section'),
        isEmpty,
      );
    });

    test('#お題「世界」 — 全角句読点で停止し #お題 のみタグ成立', () {
      expect(parseHashtagsForTesting('#お題「世界」'), ['お題']);
    });

    test('行頭の #capsicum はタグ成立', () {
      expect(parseHashtagsForTesting('#capsicum 投稿テスト'), ['capsicum']);
    });

    test('文中の空白後 #タグ もタグ成立', () {
      expect(parseHashtagsForTesting('本文です #日記 続き'), ['日記']);
    });

    test('日本語直後の #タグ — Mastodon は \\w lookbehind なのでタグ成立', () {
      // 注: Misskey は空白 / 行頭以外を弾くが、Mastodon 寄せ方針 (#566) のため許容
      expect(parseHashtagsForTesting('ねこ#にゃー'), ['にゃー']);
    });

    test('ASCII 英数字直後の #タグ は非ハッシュタグ', () {
      expect(parseHashtagsForTesting('abc#tag'), isEmpty);
      expect(parseHashtagsForTesting('123#tag'), isEmpty);
    });

    test('= 直後の #タグ は非ハッシュタグ', () {
      expect(parseHashtagsForTesting('color=#fff'), isEmpty);
    });

    test(') 直後の #タグ は非ハッシュタグ', () {
      expect(parseHashtagsForTesting('foo)#tag'), isEmpty);
    });

    test('#123 — 数字のみのタグは非ハッシュタグ', () {
      expect(parseHashtagsForTesting('#123 投稿'), isEmpty);
    });

    test('#日本語 — CJK letter のみでもタグ成立', () {
      expect(parseHashtagsForTesting('#日本語'), ['日本語']);
    });

    test('改行直後の #タグ はタグ成立', () {
      expect(parseHashtagsForTesting('1 行目\n#日記'), ['日記']);
    });

    test('#tag1 #tag2 — 複数タグ', () {
      expect(parseHashtagsForTesting('#tag1 #tag2'), ['tag1', 'tag2']);
    });

    test('#under_score — _ を含むタグ', () {
      expect(parseHashtagsForTesting('#under_score'), ['under_score']);
    });

    test('#hyphen-tag — ハイフンを含むタグ', () {
      expect(parseHashtagsForTesting('#hyphen-tag'), ['hyphen-tag']);
    });
  });

  // #1151: Misskey の投稿（MFM）は、どの文字までをタグとするかを mfm-js に
  // 合わせる。⚠ 期待値は mfm.js の `src/internal/parser.ts` の `hashTagChar` を
  // 読んで決めた（終わらせる文字は 空白 と `.,!?'"#:/[]【】()「」（）<>`）。
  group('Misskey の投稿: タグに使える文字は mfm-js に合わせる (#1151)', () {
    test('⚠⚠ 中黒はタグの一部（以前はここで切っていた）', () {
      expect(parseHashtagsForTesting('#ねこ・いぬ を見た'), ['ねこ・いぬ']);
      expect(parseHashtagsForTesting('#プリキュア・オールスターズ'), ['プリキュア・オールスターズ']);
    });

    test('絵文字や全角の記号もタグの一部（mfm-js が終わらせない文字）', () {
      expect(parseHashtagsForTesting('#ねこ🐈 かわいい'), ['ねこ🐈']);
      expect(parseHashtagsForTesting('#やった！ うれしい'), ['やった！']);
    });

    test('ASCII の句読点・コロン・スラッシュでは終わる', () {
      expect(parseHashtagsForTesting('#tag. 続き'), ['tag']);
      expect(parseHashtagsForTesting('#tag, 続き'), ['tag']);
      expect(parseHashtagsForTesting('#tag!'), ['tag']);
      expect(parseHashtagsForTesting('#tag:x'), ['tag']);
      expect(parseHashtagsForTesting('#tag/x'), ['tag']);
    });

    test('全角スペースで終わる', () {
      expect(parseHashtagsForTesting('#ねこ　いぬ'), ['ねこ']);
    });

    // ⚠⚠ ここだけ、意図して mfm-js から外れている（2026-10-10 pooza）。mfm-js は
    // 括弧の対を中身ごとタグに含めるが、そこまで合わせると #566 で直した
    // 見え方が Misskey の投稿では元に戻る。
    group('⚠ 括弧の対の中身は取り込まない（mfm-js と違う）', () {
      test('開き括弧でタグが切れる', () {
        expect(parseHashtagsForTesting('#お題「世界」'), ['お題']);
        expect(parseHashtagsForTesting('#お題（世界）'), ['お題']);
        expect(parseHashtagsForTesting('#topic(world)'), ['topic']);
        expect(parseHashtagsForTesting('#topic[world]'), ['topic']);
        expect(parseHashtagsForTesting('#お題【世界】'), ['お題']);
      });

      test('⚠⚠ #566 の出発点だった形は、タグにならないまま', () {
        expect(
          parseHashtagsForTesting('#26「夏だ！海だ！キラパティ漂流記！」を視聴。'),
          isEmpty,
          reason: '括弧で切れて「26」＝数字だけになり、成立しない',
        );
      });
    });

    test('数字だけのタグは成立しない', () {
      expect(parseHashtagsForTesting('#2026'), isEmpty);
      expect(parseHashtagsForTesting('#2026年'), ['2026年']);
    });
  });
}

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:test/test.dart';

/// #687 劇中ワードサジェストの一括取得 + ローカル絞り込み。
///
/// [filterWordSuggestions] / [normalizeReadingQuery] がサーバー
/// `PronunciationDictionary#suggest`（rank 0=読み前方一致 / 1=表層前方一致 /
/// 2=読み部分一致、同ランクは読みの辞書順→短い順）と同じ挙動になることを検証する。
/// ここが崩れると都度クエリと候補の並びが食い違う。
void main() {
  WordSuggestion w(String surface, String reading, [String? category]) =>
      WordSuggestion(surface: surface, reading: reading, category: category);

  group('normalizeReadingQuery', () {
    test('ひらがなをカタカナへ寄せる', () {
      expect(normalizeReadingQuery('せんかれっこうけん'), 'センカレッコウケン');
    });

    test('カタカナはそのまま', () {
      expect(normalizeReadingQuery('センカ'), 'センカ');
    });

    test('前後空白を除く', () {
      expect(normalizeReadingQuery('  せんか  '), 'センカ');
    });

    test('小書き・長音も範囲内で正しく写す', () {
      expect(normalizeReadingQuery('ぁぃぅーっ'), 'ァィゥーッ');
    });
  });

  group('filterWordSuggestions — ランクと並び', () {
    final entries = [
      w('閃華裂光拳', 'センカレッコウケン', '技名'),
      w('戦火', 'センカ'),
      w('先客', 'センキャク'),
      w('宣戦', 'センセン'),
      w('挑戦', 'チョウセン'),
    ];

    test('ひらがなクエリが読み前方一致 (rank0) を拾う', () {
      final r = filterWordSuggestions(entries, 'せんか');
      // "センカ"(戦火) と "センカレッコウケン"(閃華裂光拳) が読み前方一致。
      // 同ランクは読みの辞書順→短い順 = "センカ" が先。
      expect(r.map((e) => e.surface), ['戦火', '閃華裂光拳']);
    });

    test('表層前方一致 (rank1) は読み一致の後に来る', () {
      // クエリ "先" は読み(センキャク等)には前方一致しないが、表層 "先客" に
      // 前方一致する (rank1)。読み前方一致が無いので rank1 が先頭。
      final r = filterWordSuggestions(entries, '先');
      expect(r.map((e) => e.surface), ['先客']);
    });

    test('読み部分一致 (rank2) は前方一致より後', () {
      // "せん" は センカ/センカレッコウケン/センキャク/センセン に前方一致(rank0)、
      // チョウセン には部分一致(rank2)。rank0 群が読みの辞書順(センカ は
      // センカレッコウケン の接頭辞なので短い方が先)、最後に rank2 のチョウセン。
      final r = filterWordSuggestions(entries, 'せん');
      expect(r.map((e) => e.reading), [
        'センカ',
        'センカレッコウケン',
        'センキャク',
        'センセン',
        'チョウセン',
      ]);
    });

    test('limit の件数だけ返す', () {
      final r = filterWordSuggestions(entries, 'せん', limit: 2);
      expect(r.length, 2);
      expect(r.map((e) => e.reading), ['センカ', 'センカレッコウケン']);
    });

    test('マッチ無しは空', () {
      expect(filterWordSuggestions(entries, 'ぬるぽ'), isEmpty);
    });

    test('空クエリ・空白のみは空', () {
      expect(filterWordSuggestions(entries, ''), isEmpty);
      expect(filterWordSuggestions(entries, '   '), isEmpty);
    });
  });

  group('queryMayNeedServerNormalization', () {
    test('純粋なかな/漢字は fallback 不要', () {
      expect(queryMayNeedServerNormalization('せんか'), isFalse);
      expect(queryMayNeedServerNormalization('閃華'), isFalse);
    });

    test('半角カナは fallback 対象', () {
      expect(queryMayNeedServerNormalization('ｾﾝｶ'), isTrue);
    });

    test('全角英数は fallback 対象', () {
      expect(queryMayNeedServerNormalization('ＡＢＣ'), isTrue);
    });
  });
}

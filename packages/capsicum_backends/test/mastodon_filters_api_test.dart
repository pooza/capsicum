import 'package:capsicum_backends/src/mastodon/filters.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';

/// #1047: Mastodon の `api/v2/filters` の読み書き。
void main() {
  group('parseMastodonFilter', () {
    test('キーワード・適用先・動作・期限を読む', () {
      final filter = parseMastodonFilter({
        'id': 12,
        'title': 'ネタバレ',
        'context': ['home', 'notifications', 'someday'],
        'expires_at': '2026-10-16T00:00:00.000Z',
        'filter_action': 'blur',
        'keywords': [
          {'id': '3', 'keyword': 'ダイ', 'whole_word': false},
        ],
        'statuses': <Object>[],
      });

      expect(filter.id, '12', reason: 'id は数値で来ても文字列にする');
      expect(filter.title, 'ネタバレ');
      expect(filter.contexts, {
        FilterContext.home,
        FilterContext.notifications,
      }, reason: '知らない適用先は読み捨てる');
      expect(filter.action, FilterAction.blur);
      expect(filter.expiresAt, DateTime.utc(2026, 10, 16));
      expect(filter.keywords.single.id, '3');
      expect(filter.keywords.single.keyword, 'ダイ');
      expect(filter.keywords.single.wholeWord, isFalse);
    });

    test('期限が無ければ無期限・知らない動作は warn', () {
      final filter = parseMastodonFilter({
        'id': '1',
        'title': 't',
        'context': ['public'],
        'expires_at': null,
        'filter_action': 'shout',
      });
      expect(filter.expiresAt, isNull);
      expect(filter.action, FilterAction.warn);
      expect(filter.keywords, isEmpty);
    });

    // #1293: 読み捨てると、編集して保存したときにサーバー側から消える。
    test('⚠⚠ 知らない適用先と動作は、生の値で残す', () {
      final filter = parseMastodonFilter({
        'id': '1',
        'title': 't',
        'context': ['public', 'quotes'],
        'filter_action': 'shout',
      });
      expect(filter.contexts, {FilterContext.public});
      expect(filter.unknownContexts, ['quotes']);
      expect(filter.unknownAction, 'shout');
    });

    test('知っている動作なら unknownAction は null', () {
      final filter = parseMastodonFilter({
        'id': '1',
        'title': 't',
        'context': ['public'],
        'filter_action': 'blur',
      });
      expect(filter.unknownAction, isNull);
      expect(filter.unknownContexts, isEmpty);
    });

    // #1293: Web の「この投稿をフィルター」で作ったものはキーワードを持たない。
    test('投稿単位の登録の数を読む', () {
      final filter = parseMastodonFilter({
        'id': '1',
        'title': 't',
        'context': ['home'],
        'filter_action': 'warn',
        'keywords': <Object>[],
        'statuses': [
          {'id': 's1', 'status_id': '100'},
          {'id': 's2', 'status_id': '101'},
        ],
      });
      expect(filter.keywords, isEmpty);
      expect(filter.statusCount, 2);
    });

    test('期限切れの判定', () {
      final filter = parseMastodonFilter({
        'id': '1',
        'title': 't',
        'context': ['public'],
        'expires_at': '2026-10-15T00:00:00Z',
        'filter_action': 'warn',
      });
      expect(filter.isExpiredAt(DateTime.utc(2026, 10, 15, 1)), isTrue);
      expect(filter.isExpiredAt(DateTime.utc(2026, 10, 14)), isFalse);
    });
  });

  group('mastodonFilterBody', () {
    FilterDraft draft({
      FilterExpiry expiry = const NoFilterExpiry(),
      List<FilterKeyword> keywords = const [],
      List<String> removed = const [],
    }) => FilterDraft(
      title: 'ネタバレ',
      contexts: const {FilterContext.home, FilterContext.thread},
      action: FilterAction.hide,
      expiry: expiry,
      keywords: keywords,
      removedKeywordIds: removed,
    );

    test('名前・適用先・動作を送る', () {
      final body = mastodonFilterBody(draft());
      expect(body['title'], 'ネタバレ');
      expect(body['context'], unorderedEquals(['home', 'thread']));
      expect(body['filter_action'], 'hide');
    });

    test('⚠⚠ 知らない適用先と動作は送り返す（#1293）', () {
      final body = mastodonFilterBody(
        const FilterDraft(
          title: 't',
          contexts: {FilterContext.home},
          action: FilterAction.warn,
          unknownContexts: ['quotes'],
          rawAction: 'shout',
        ),
      );
      expect(body['context'], unorderedEquals(['home', 'quotes']));
      expect(body['filter_action'], 'shout');
    });

    // ⚠⚠ 期限は 3 通り。取り違えると、編集のたびに期限が消える / 付く。
    group('⚠⚠ 期限', () {
      test('変えない → キーを送らない', () {
        final body = mastodonFilterBody(
          draft(expiry: const KeepFilterExpiry()),
        );
        expect(body.containsKey('expires_in'), isFalse);
      });

      test('無期限 → 空文字（Mastodon は空で期限を外す）', () {
        expect(mastodonFilterBody(draft())['expires_in'], '');
      });

      test('期限つき → 秒数', () {
        final body = mastodonFilterBody(
          draft(expiry: const FilterExpiresIn(Duration(hours: 6))),
        );
        expect(body['expires_in'], 21600);
      });
    });

    test('⚠ キーワードは既存（id 付き）・新規（id 無し）・削除（_destroy）を 1 本で送る', () {
      final body = mastodonFilterBody(
        draft(
          keywords: const [
            FilterKeyword(id: '3', keyword: 'ダイ', wholeWord: false),
            FilterKeyword(keyword: 'ポップ'),
          ],
          removed: const ['4'],
        ),
      );
      expect(body['keywords_attributes'], [
        {'id': '3', 'keyword': 'ダイ', 'whole_word': false},
        {'keyword': 'ポップ', 'whole_word': true},
        {'id': '4', '_destroy': true},
      ]);
    });
  });
}

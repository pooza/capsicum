import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1289: Status の `filtered[]` から、適用先（context）と `blur` を落とさずに読む。
///
/// ⚠⚠ サーバーは一致したフィルターを**適用先に関係なくすべて**返す
/// （`custom_filter.rb` の `apply_cached_filters`）。どの画面で効かせるかは
/// クライアントの責務で、以前の capsicum は `context` を読まずに全画面で効かせていた。
void main() {
  MastodonStatus status(List<Map<String, dynamic>>? filtered) =>
      MastodonStatus.fromJson({
        'id': '1',
        'created_at': '2026-10-15T00:00:00Z',
        'account': {
          'id': '1',
          'username': 'someone',
          'acct': 'someone',
          'display_name': 'someone',
          'note': '',
          'avatar': '',
          'header': '',
          'followers_count': 0,
          'following_count': 0,
          'statuses_count': 0,
          'fields': <Map<String, dynamic>>[],
        },
        'content': '<p>ほげ</p>',
        'visibility': 'public',
        'favourites_count': 0,
        'reblogs_count': 0,
        'replies_count': 0,
        'media_attachments': <Map<String, dynamic>>[],
        'filtered': ?filtered,
      });

  Map<String, dynamic> result({
    required String action,
    Object? context = const ['home'],
    String title = 'ネタバレ',
  }) => {
    'filter': {
      'id': '9',
      'title': title,
      'context': ?context,
      'expires_at': null,
      'filter_action': action,
    },
    'keyword_matches': ['ほげ'],
    'status_matches': null,
  };

  List<FilterMatch> matchesOf(List<Map<String, dynamic>>? filtered) =>
      status(filtered).toCapsicum('mstdn.b-shock.org').filterMatches;

  test('⚠⚠ context を適用先として持つ', () {
    final matches = matchesOf([
      result(action: 'hide', context: ['notifications', 'thread']),
    ]);

    expect(matches.single.contexts, {
      FilterContext.notifications,
      FilterContext.thread,
    });
    final post = status([
      result(action: 'hide', context: ['notifications']),
    ]).toCapsicum('mstdn.b-shock.org');
    expect(post.isHiddenIn(FilterContext.notifications), isTrue);
    expect(
      post.isHiddenIn(FilterContext.home),
      isFalse,
      reason: '「通知だけ」のフィルターがホームで効いてはいけない',
    );
  });

  test('⚠ blur を warn に落とさない（4.7 の「メディアをぼかす」）', () {
    expect(
      matchesOf([result(action: 'blur')]).single.action,
      FilterAction.blur,
    );
  });

  test('warn / hide はそのまま', () {
    expect(
      matchesOf([result(action: 'warn')]).single.action,
      FilterAction.warn,
    );
    expect(
      matchesOf([result(action: 'hide')]).single.action,
      FilterAction.hide,
    );
  });

  test('知らない filter_action は warn（伏せる側に倒す）', () {
    expect(
      matchesOf([result(action: 'shout')]).single.action,
      FilterAction.warn,
    );
  });

  test('⚠ 一致したフィルターを全部持つ（最初の 1 件で止めない）', () {
    final matches = matchesOf([
      result(action: 'warn', title: 'A', context: ['public']),
      result(action: 'hide', title: 'B', context: ['home']),
    ]);
    expect(matches.map((m) => m.title), ['A', 'B']);
  });

  test('知らない適用先は読み捨てる（空集合ならどこにも効かない）', () {
    final match = matchesOf([
      result(action: 'hide', context: ['someday']),
    ]).single;
    expect(match.contexts, isEmpty);
  });

  test('context が無い要素は全画面（null）', () {
    expect(
      matchesOf([result(action: 'warn', context: null)]).single.contexts,
      isNull,
    );
  });

  test('filtered が無い・空なら一致なし', () {
    expect(matchesOf(null), isEmpty);
    expect(matchesOf([]), isEmpty);
  });
}

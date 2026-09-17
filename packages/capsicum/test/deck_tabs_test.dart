import 'package:capsicum/src/ui/util/deck_tabs.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1150: ユーザー一覧・引用一覧の取得先。
///
/// ⚠ 以前は投稿タイルの中にあった振り分けを `deck_tabs.dart` へ寄せた。デッキの
/// カラムと全画面の両方がここを通るので、**呼ぶ API がバックエンドで違うこと**を
/// ここで固定する（寄せたときに取り違えると、両方の出し方で同時に壊れる）。
class _Mastodon extends Mock implements MastodonAdapter {}

class _Misskey extends Mock implements MisskeyAdapter {}

class _Plain extends Mock implements DecentralizedBackendAdapter {}

const _empty = (users: <User>[], nextCursor: null);

void main() {
  setUpAll(() => registerFallbackValue(const TimelineQuery()));

  test('お気に入り: Mastodon は favourited_by、Misskey はリアクションした人全員', () async {
    final mastodon = _Mastodon();
    when(
      () => mastodon.getFavouritedBy('p1', query: any(named: 'query')),
    ).thenAnswer((_) async => _empty);
    await userListFetcher(
      mastodon,
      const UserListTab(UserListKind.favouritedBy, 'p1'),
    )!(null);
    verify(
      () => mastodon.getFavouritedBy('p1', query: any(named: 'query')),
    ).called(1);

    final misskey = _Misskey();
    when(
      () => misskey.getReactedBy(
        'p1',
        type: any(named: 'type'),
        query: any(named: 'query'),
      ),
    ).thenAnswer((_) async => _empty);
    await userListFetcher(
      misskey,
      const UserListTab(UserListKind.favouritedBy, 'p1'),
    )!(null);
    verify(
      () => misskey.getReactedBy('p1', type: null, query: any(named: 'query')),
    ).called(1);
  });

  test('ブースト: Mastodon は reblogged_by、Misskey はリノートした人', () async {
    final mastodon = _Mastodon();
    when(
      () => mastodon.getRebloggedBy('p1', query: any(named: 'query')),
    ).thenAnswer((_) async => _empty);
    await userListFetcher(
      mastodon,
      const UserListTab(UserListKind.rebloggedBy, 'p1'),
    )!(null);
    verify(
      () => mastodon.getRebloggedBy('p1', query: any(named: 'query')),
    ).called(1);

    final misskey = _Misskey();
    when(
      () => misskey.getRenotedBy('p1', query: any(named: 'query')),
    ).thenAnswer((_) async => _empty);
    await userListFetcher(
      misskey,
      const UserListTab(UserListKind.rebloggedBy, 'p1'),
    )!(null);
    verify(
      () => misskey.getRenotedBy('p1', query: any(named: 'query')),
    ).called(1);
  });

  test('絵文字ごとのリアクションは絵文字を渡し、カーソルも渡す', () async {
    final misskey = _Misskey();
    when(
      () => misskey.getReactedBy(
        'p1',
        type: any(named: 'type'),
        query: any(named: 'query'),
      ),
    ).thenAnswer((_) async => _empty);
    await userListFetcher(
      misskey,
      const UserListTab(UserListKind.reactedBy, 'p1', reaction: ':blob@.:'),
    )!('cursor-1');
    final query =
        verify(
              () => misskey.getReactedBy(
                'p1',
                type: ':blob@.:',
                query: captureAny(named: 'query'),
              ),
            ).captured.single
            as TimelineQuery;
    expect(query.maxId, 'cursor-1');
    expect(query.limit, 20);
  });

  test('対応していないアダプタでは null（開く導線を出さない）', () {
    final plain = _Plain();
    for (final kind in UserListKind.values) {
      expect(
        userListFetcher(plain, UserListTab(kind, 'x')),
        isNull,
        reason: kind.name,
      );
    }
    expect(
      userListFetcher(null, const UserListTab(UserListKind.followers, 'x')),
      isNull,
    );
    // Mastodon に絵文字ごとのリアクションは無い。
    expect(
      userListFetcher(
        _Mastodon(),
        const UserListTab(UserListKind.reactedBy, 'p1', reaction: ':a:'),
      ),
      isNull,
    );
    expect(quotesFetcher(plain, 'p1'), isNull);
  });
}

import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1054: 編集済み投稿に印を出すための `edited_at` を Status → Post へ通す。
///
/// ⚠ **これは「読む側」の話**で、自分の投稿を書き換える「投稿の更新」
/// （`docs/CLAUDE.md` の実装しない機能）とは別物。混同して消さないこと。
///
/// ⚠ pooza の自サーバーは本文の編集を無効にしているが、**連合先で編集された投稿は
/// 編集済みとして届く**ので、自サーバーの設定では防げない。
void main() {
  MastodonStatus status(Map<String, dynamic> overrides) =>
      MastodonStatus.fromJson({
        'id': '1',
        'created_at': '2026-09-11T00:00:00Z',
        'account': {
          'id': '1',
          'username': 'pooza',
          'acct': 'pooza',
          'display_name': 'pooza',
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
        ...overrides,
      });

  group('edited_at → Post.editedAt', () {
    test('編集済みの投稿は編集時刻を持つ', () {
      final post = status({
        'edited_at': '2026-09-12T03:04:05Z',
      }).toCapsicum('mstdn.b-shock.org');

      expect(post.editedAt, DateTime.utc(2026, 9, 12, 3, 4, 5));
      // 投稿時刻は編集時刻に上書きされない（印は「いつ編集されたか」を出す）。
      expect(post.postedAt, DateTime.utc(2026, 9, 11));
    });

    test('⚠ 編集されていない投稿は null（印を出さない条件そのもの）', () {
      expect(status({}).toCapsicum('mstdn.b-shock.org').editedAt, isNull);
    });

    test('⚠ edited_at が明示的に null でも落ちない', () {
      expect(
        status({'edited_at': null}).toCapsicum('mstdn.b-shock.org').editedAt,
        isNull,
      );
    });

    test('ブーストは中身（reblog）の編集時刻を持つ', () {
      final post = status({
        'reblog': {
          'id': '2',
          'created_at': '2026-09-10T00:00:00Z',
          'edited_at': '2026-09-12T03:04:05Z',
          'account': {
            'id': '2',
            'username': 'someone',
            'acct': 'someone@example.com',
            'display_name': 'someone',
            'note': '',
            'avatar': '',
            'header': '',
            'followers_count': 0,
            'following_count': 0,
            'statuses_count': 0,
            'fields': <Map<String, dynamic>>[],
          },
          'content': '<p>ふが</p>',
          'visibility': 'public',
          'favourites_count': 0,
          'reblogs_count': 0,
          'replies_count': 0,
          'media_attachments': <Map<String, dynamic>>[],
        },
      }).toCapsicum('mstdn.b-shock.org');

      // 印を出すのは表示される投稿（= reblog の中身）。外側は編集されていない。
      expect(post.reblog!.editedAt, DateTime.utc(2026, 9, 12, 3, 4, 5));
      expect(post.editedAt, isNull);
    });

    test('copyWith は編集時刻を落とさない（enrich パイプラインで消えない）', () {
      final post = status({
        'edited_at': '2026-09-12T03:04:05Z',
      }).toCapsicum('mstdn.b-shock.org');

      expect(post.copyWith(bookmarked: true).editedAt, post.editedAt);
    });
  });
}

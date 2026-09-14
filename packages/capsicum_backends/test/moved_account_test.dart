import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:capsicum_backends/src/misskey/extensions.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1055: 引っ越し済み・凍結・サイレンス・削除済みのアカウントを、普通の
/// プロフィールとして出さないためのモデル側の下ごしらえ。
///
/// ⚠ **引っ越しを「する」側は対象外**（棚卸しの分類 C）。ここは「見る側」だけ。
///
/// ⚠ **分かる粒度がサーバーで違う**のが要点。Mastodon の `moved` は Account
/// そのもの（handle まで分かる）、Misskey の `movedTo` は AP URI 1 本。
void main() {
  Map<String, dynamic> account(Map<String, dynamic> overrides) => {
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
    ...overrides,
  };

  MastodonAccount mastodon(Map<String, dynamic> overrides) =>
      MastodonAccount.fromJson(account(overrides));

  MisskeyUser misskey(Map<String, dynamic> overrides) =>
      MisskeyUser.fromJson({'id': '1', 'username': 'pooza', ...overrides});

  group('Mastodon の moved', () {
    test('引っ越し先の handle / URL / ID を拾う', () {
      final user = mastodon({
        'moved': account({
          'id': '99',
          'username': 'pooza',
          'acct': 'pooza@mstdn.b-shock.org',
          'url': 'https://mstdn.b-shock.org/@pooza',
        }),
      }).toCapsicum('example.com');

      expect(user.movedTo, isNotNull);
      expect(user.movedTo!.handle, '@pooza@mstdn.b-shock.org');
      expect(user.movedTo!.url, 'https://mstdn.b-shock.org/@pooza');
      expect(user.movedTo!.userId, '99');
    });

    test('⚠ 引っ越していなければ null（バッジを出さない条件そのもの）', () {
      expect(mastodon({}).toCapsicum('example.com').movedTo, isNull);
    });

    test('⚠ url の無い moved は捨てる（行き先を示せないバッジを出さない）', () {
      final user = mastodon({
        'moved': account({'id': '99', 'acct': 'pooza@mstdn.b-shock.org'}),
      }).toCapsicum('example.com');

      expect(user.movedTo, isNull);
    });

    test('⚠ Mastodon では凍結 / サイレンス / 削除済みは常に false', () {
      // REST の Account に相当フィールドが無い。Misskey 側の値を Mastodon の
      // プロフィールへ混ぜないことの確認。
      final user = mastodon({}).toCapsicum('example.com');
      expect(user.suspended, isFalse);
      expect(user.silenced, isFalse);
      expect(user.deleted, isFalse);
    });
  });

  group('Misskey の movedTo と状態フラグ', () {
    test('movedTo は URL だけ入り、handle は null のまま', () {
      final user = misskey({
        'movedTo': 'https://misskey.delmulin.com/users/9abc',
      }).toCapsicum('example.com');

      expect(user.movedTo, isNotNull);
      expect(user.movedTo!.url, 'https://misskey.delmulin.com/users/9abc');
      // ⚠ AP URI からは @user@host を作れない。画面は URL を出す。
      expect(user.movedTo!.handle, isNull);
      expect(user.movedTo!.userId, isNull);
    });

    test('⚠ 空文字の movedTo は引っ越し扱いにしない', () {
      expect(
        misskey({'movedTo': ''}).toCapsicum('example.com').movedTo,
        isNull,
      );
    });

    test('凍結 / サイレンス / 削除済みを拾う', () {
      final user = misskey({
        'isSuspended': true,
        'isSilenced': true,
        'isDeleted': true,
      }).toCapsicum('example.com');

      expect(user.suspended, isTrue);
      expect(user.silenced, isTrue);
      expect(user.deleted, isTrue);
    });

    test('⚠ 未取得（null）は false へ倒す', () {
      final user = misskey({}).toCapsicum('example.com');
      expect(user.suspended, isFalse);
      expect(user.silenced, isFalse);
      expect(user.deleted, isFalse);
      expect(user.movedTo, isNull);
    });
  });

  test('copyWithIsCat は引っ越し先と状態フラグを落とさない', () {
    final user = misskey({
      'movedTo': 'https://misskey.delmulin.com/users/9abc',
      'isSuspended': true,
    }).toCapsicum('example.com');

    final enriched = user.copyWithIsCat(true);
    expect(enriched.movedTo?.url, user.movedTo!.url);
    expect(enriched.suspended, isTrue);
  });
}

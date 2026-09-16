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

    test('キーが来ないときは凍結 / サイレンス / 削除済みとも false', () {
      // serializer が `if: :unavailable?` / `if: :silenced?` 付きなので、
      // 該当しないアカウントでは**キーごと来ない**。null を false へ畳む。
      final user = mastodon({}).toCapsicum('example.com');
      expect(user.suspended, isFalse);
      expect(user.silenced, isFalse);
      expect(user.deleted, isFalse);
    });

    test('⚠⚠ 凍結を拾う（「Mastodon には相当フィールドが無い」は誤りだった）', () {
      // `account_serializer.rb`: `attribute :suspended, if: :unavailable?`。
      // 通常の /api/v1/accounts/:id で返る。v1.65 のリリース前レビューまで
      // 読んでおらず、#1055 がプリセット 4 台中 3 台で効いていなかった。
      final user = mastodon({'suspended': true}).toCapsicum('example.com');
      expect(user.suspended, isTrue);
      expect(user.silenced, isFalse);
    });

    test('⚠⚠ サイレンスの JSON キーは silenced ではなく limited', () {
      // serializer が `attribute :silenced, key: :limited` と改名している。
      // ⚠ これが歯 —— `silenced` を読む実装に戻すとこのテストが落ちる。
      final user = mastodon({'limited': true}).toCapsicum('example.com');
      expect(user.silenced, isTrue);
      expect(user.suspended, isFalse);
    });

    test('⚠ silenced というキーで来ても読まない（改名前の綴りに戻さないための固定）', () {
      final user = mastodon({'silenced': true}).toCapsicum('example.com');
      expect(user.silenced, isFalse);
    });

    test('⚠ 削除済みは Mastodon では suspended に畳まれる', () {
      // `unavailable? = deleted? || suspended?` なので、削除済みでも
      // 立つのは suspended 側。deleted を別に期待しない。
      final user = mastodon({'suspended': true}).toCapsicum('example.com');
      expect(user.deleted, isFalse);
    });
  });

  group('Misskey の movedTo と状態フラグ', () {
    test('⚠⚠ movedTo は URI ではなくユーザー ID として入る', () {
      // Misskey が返すのは AP URI ではなく**ローカル DB の aid**。
      // `UserEntityService` が `resolvePerson(movedToUri).then(u => u.id)` を
      // 返しており、json-schema の `format: 'uri'` は実装と合っていない。
      // ⚠ 以前はこれを `url` に入れていたため、画面に生の ID が出たうえ
      // タップしても開けなかった（v1.65 のリリース前レビューで訂正）。
      final user = misskey({'movedTo': '9abc'}).toCapsicum('example.com');

      expect(user.movedTo, isNotNull);
      expect(user.movedTo!.userId, '9abc');
      // ⚠ **url は null。**開けないものをリンクに見せないため、画面は
      // `url == null` のときタップ不可のバッジにする。
      expect(user.movedTo!.url, isNull);
      expect(user.movedTo!.handle, isNull);
    });

    test('⚠ URL 形の値が来ても url には入れない（サーバー実装が変わっても誤リンクを作らない）', () {
      // 将来 Misskey が URI を返すようになっても、こちら側が勝手に
      // 「URL だから開ける」と判断しないことの固定。解決は別途 users/show で行う。
      final user = misskey({
        'movedTo': 'https://misskey.delmulin.com/users/9abc',
      }).toCapsicum('example.com');

      expect(user.movedTo!.url, isNull);
      expect(user.movedTo!.userId, 'https://misskey.delmulin.com/users/9abc');
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

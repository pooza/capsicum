import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1194: Mastodon の投稿設定の既定を `source` から読む。
///
/// ⚠⚠ **WebUI は 4 つを同じ画面で設定するのに、capsicum は `privacy` しか
/// 追従していなかった。**サーバーは 4 つとも返している
/// （`REST::CredentialAccountSerializer#source`・2026-10-01 にフォークで実測）:
///
/// ```ruby
/// { privacy:, sensitive:, language:, quote_policy:, ... }
/// ```
///
/// 🔴 とくに `language` は**読まずに端末ロケールを送っていた**ので、
/// 「送らなければサーバー既定が効く」という逃げが効かず、**WebUI の設定が常に
/// 上書きされていた**。
void main() {
  MastodonAccount account(Map<String, dynamic> overrides) =>
      MastodonAccount.fromJson({
        'id': '1',
        'username': 'capsicum',
        'acct': 'capsicum',
        'display_name': 'capsicum',
        'note': '',
        'avatar': '',
        'header': '',
        'followers_count': 0,
        'following_count': 0,
        'statuses_count': 0,
        'fields': <Map<String, dynamic>>[],
        ...overrides,
      });

  group('source の既定を読む (#1194)', () {
    test('4 つとも読む', () {
      final user = account({
        'source': {
          'privacy': 'unlisted',
          'language': 'ja',
          'quote_policy': 'followers',
          'sensitive': true,
        },
      }).toCapsicum('example.com');

      expect(user.defaultScope, PostScope.unlisted);
      expect(user.defaultLanguage, 'ja');
      expect(user.defaultQuotePolicy, 'followers');
      expect(user.defaultSensitive, isTrue);
    });

    // ⚠ `setting_default_language` は WebUI で「未設定」にできる。null が普通に
    // 来るので、呼ぶ側が端末ロケールへ倒せるよう **null のまま**返す。
    test('⚠ 未設定の言語は null のまま（既定値を捏造しない）', () {
      final user = account({
        'source': {'privacy': 'public', 'language': null},
      }).toCapsicum('example.com');

      expect(user.defaultLanguage, isNull);
    });

    // ⚠⚠ **これが実際に踏んだ形 (#1194)。**WebUI で「サイトの表示言語に合わせる」
    // を選ぶと、サーバーは null ではなく `''` を返す。`<select>` の nil 選択肢が
    // `value=""` で、`UserSettings#[]=` は `''` を nil でないものとして保存する
    // （`in:` の検証が無い `language` だけこれが起きる）。
    //
    // ⚠ 素通しすると `?? 端末ロケール` が効かず、**投稿フォームの言語が空欄で
    // 開く**。上の null のテストだけでは**この穴を塞げていなかった**。
    test('⚠⚠ 「表示言語に合わせる」の空文字も null へ畳む', () {
      final user = account({
        'source': {'privacy': 'public', 'language': ''},
      }).toCapsicum('example.com');

      expect(
        user.defaultLanguage,
        isNull,
        reason: '⚠ `\'\'` を持つと呼ぶ側が端末ロケールへ倒せず、言語が空欄になる',
      );
    });

    // ⚠⚠ `source` は `verify_credentials` にしか無い。他人の Account では
    // 丸ごと欠けるので、全部 null に倒れること。
    test('⚠⚠ source が無い（他人の Account）なら全部 null', () {
      final user = account({}).toCapsicum('example.com');

      expect(user.defaultScope, isNull);
      expect(user.defaultLanguage, isNull);
      expect(user.defaultQuotePolicy, isNull);
      expect(
        user.defaultSensitive,
        isNull,
        reason: '⚠ false に倒すと「既定は OFF」と誤読され、送る / 送らないの判断を誤る',
      );
    });

    // ⚠ 上流が policy を増やしても素通しで持つ（capsicum 側で enum に直さない）。
    test('⚠ 知らない quote_policy もそのまま持つ', () {
      final user = account({
        'source': {'privacy': 'public', 'quote_policy': 'mutuals'},
      }).toCapsicum('example.com');

      expect(user.defaultQuotePolicy, 'mutuals');
    });

    // 対照群。`privacy` の既存の読み取りを壊していないこと。
    test('privacy は従来どおり（対照群）', () {
      expect(
        account({
          'source': {'privacy': 'direct'},
        }).toCapsicum('example.com').defaultScope,
        PostScope.direct,
      );
    });
  });
}

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';

/// #1109: アダプターが `forceLogin` を出し分けられること。
///
/// ⚠⚠ **呼び出し側（`login_screen`）は v1.65 から常に `true` を渡す**（#1143）。
/// #1109 は「このサーバーに既にアカウントを持っているときだけ付ける」形にしたが、
/// リリース前レビューで前提が崩れた:
///
/// - **省いても速くならない** —— フォークで `force_login` を見ているのは
///   `can_authorize_response?` の 1 か所だけで、**同意画面を必ず出す**効果しか
///   無い。認証を担う `resource_owner_authenticator` は参照していない
/// - **「アカウントの有無」では危険な経路を覆えない** —— capsicum は削除時に
///   トークンを revoke しないので、@a を消して @b を足すと判定は false なのに
///   サーバー側の @a のトークンが生きており、**@a が黙って戻ってくる**
///
/// ⚠ **それでもアダプター側の出し分けは残す。**判断は呼び出し側が持つ、という
/// 構造は変えていない（既定は true）。ここはその契約の固定。
void main() {
  ApplicationInfo appInfo() => ApplicationInfo(
    name: 'capsicum',
    redirectUri: Uri.parse('http://localhost:7099/oauth/callback'),
    scopes: const ['read', 'write', 'follow', 'push'],
  );

  Future<MastodonAdapter> adapter() async {
    final a = await MastodonAdapter.create('mastodon.example');
    // POST /api/v1/apps を踏ませない（startLogin をネットワーク非依存にする）。
    a.setCachedClientCredentials(
      ClientSecretData(clientId: 'cid', clientSecret: 'csecret'),
    );
    return a;
  }

  Future<Map<String, String>> authorizeQuery({bool? forceLogin}) async {
    final a = await adapter();
    final result = forceLogin == null
        ? await a.startLogin(appInfo())
        : await a.startLogin(appInfo(), forceLogin: forceLogin);
    return (result as LoginNeedsOAuth).authorizationUrl.queryParameters;
  }

  test('⚠ 既定は従来どおり force_login=true（呼び出し側が明示しない限り変えない）', () async {
    expect(await authorizeQuery(), containsPair('force_login', 'true'));
  });

  test('forceLogin: true なら付く', () async {
    expect(
      await authorizeQuery(forceLogin: true),
      containsPair('force_login', 'true'),
    );
  });

  test('⚠ forceLogin: false なら「false」を送るのではなくパラメータ自体を落とす', () async {
    // `force_login=false` を送る実装にすると、上流が値を真偽で解釈しない場合に
    // 付いているのと同じ扱いになりうる。落とすのが正しい。
    expect(
      await authorizeQuery(forceLogin: false),
      isNot(contains('force_login')),
    );
  });

  test('forceLogin を外しても PKCE / state は残る（認可の安全性を落とさない）', () async {
    final q = await authorizeQuery(forceLogin: false);

    expect(q['code_challenge_method'], 'S256');
    expect(q['code_challenge'], isNotNull);
    expect(q['state'], isNotNull);
    expect(q['response_type'], 'code');
    expect(q['scope'], 'read write follow push');
  });

  test('Misskey は forceLogin を無視する（MiAuth に相当概念が無い）', () async {
    final a = await MisskeyAdapter.create('misskey.example');

    final forced = await a.startLogin(appInfo(), forceLogin: true);
    final notForced = await a.startLogin(appInfo(), forceLogin: false);

    // セッション ID だけが違い、他は同じ形の MiAuth URL になる。
    for (final result in [forced, notForced]) {
      final url = (result as LoginNeedsOAuth).authorizationUrl;
      expect(url.path, startsWith('/miauth/'));
      expect(url.queryParameters, isNot(contains('force_login')));
    }
  });
}

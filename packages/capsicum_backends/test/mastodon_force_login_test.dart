import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';

/// #1109: `force_login=true` を「このサーバーに既にアカウントを持っているとき」
/// だけ付けられるようにする。
///
/// ⚠ **なぜ付けたままにしないか。**認可待ちの keep-alive は約 3 分で打ち切られる
/// （#1108）のに、`force_login=true` は ID / パスワード入力・パスワードマネージャ
/// や 2FA との往復を毎回強制し、その 3 分を確実に削る。
///
/// ⚠ **なぜ全部外さないか。**同じサーバーの 2 人目以降は、ブラウザのセッションで
/// 1 人目が黙って選ばれてしまう（意図した相手が入らない）。判断は呼び出し側
/// （`login_screen`）が持ち、既定は従来どおり true。
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

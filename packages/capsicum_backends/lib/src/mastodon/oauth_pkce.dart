import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// OAuth 認可コード横取り対策（PKCE + `state`・#790）のパラメータ一式。
///
/// loopback / カスタムスキームの callback は同一端末の別アプリやブラウザで開いた
/// 任意ページからも到達しうる。`state`（callback で照合し不一致を拒否）と PKCE
/// （RFC 7636・code_verifier を token 交換時に送る）を認可フローに付与することで、
/// 攻撃者コードの注入（login-CSRF / セッション固定）を防ぐ。Mastodon は両方に対応。
class OAuthPkceParams {
  /// 認可リクエストに載せ、callback の `state` と照合する高エントロピー値。
  final String state;

  /// PKCE の verifier。token 交換時にのみ送る秘密（認可リクエストには載せない）。
  final String codeVerifier;

  /// PKCE の challenge。認可リクエストに載せる（[codeChallengeMethod] で変換）。
  final String codeChallenge;

  const OAuthPkceParams({
    required this.state,
    required this.codeVerifier,
    required this.codeChallenge,
  });

  /// challenge の変換方式。Mastodon は S256 を要求する。
  static const codeChallengeMethod = 'S256';

  /// 高エントロピーな新規パラメータを生成する。
  factory OAuthPkceParams.generate() {
    // 32 byte → padding 除去後 43 文字。RFC 7636 の 43〜128 文字要件を満たす。
    final verifier = _randomToken(32);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    return OAuthPkceParams(
      state: _randomToken(16),
      codeVerifier: verifier,
      codeChallenge: challenge,
    );
  }

  /// URL-safe な高エントロピー文字列（padding 無し base64url）。
  ///
  /// base64url の文字集合（`A-Za-z0-9-_`）は PKCE verifier の unreserved 集合に
  /// 含まれるが、padding の `=` は含まれないため除去する。
  static String _randomToken(int bytes) {
    final rng = Random.secure();
    final values = List<int>.generate(bytes, (_) => rng.nextInt(256));
    return base64Url.encode(values).replaceAll('=', '');
  }
}

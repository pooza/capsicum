import 'login_support.dart';

/// 自分のアクセストークンをサーバー側で取り消す (#1401)。
///
/// アカウントを削除したときに呼ぶ。呼ばないと、サーバーの「連携アプリ」に
/// capsicum の承認が残り続け、ログインし直すたびに溜まっていく。
///
/// ⚠ 呼ぶ側は、そのトークンで動いているセッションが手元に無いと言える場面に
/// 限ること（Mastodon は `reuse_access_token` で同じトークンを返しうる・#1372）。
/// ⚠ 失敗（オフライン・既に失効・取り消しの口が無い古いサーバー）は投げる。
/// 握りつぶすかは呼ぶ側が決める。
abstract mixin class TokenRevokeSupport {
  /// [clientSecret] は Mastodon 系だけが使う（`/oauth/revoke` に要る）。
  /// Mastodon 系で null なら、取り消せないので何もしない。
  Future<void> revokeOwnToken(
    UserSecret userSecret, {
    ClientSecretData? clientSecret,
  });
}

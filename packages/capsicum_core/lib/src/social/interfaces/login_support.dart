import '../../../capsicum_core.dart';

/// Secrets for the user's access token.
class UserSecret {
  final String accessToken;
  final String? refreshToken;

  const UserSecret({required this.accessToken, this.refreshToken});
}

/// Secrets for the registered OAuth client (Mastodon only).
class ClientSecretData {
  final String clientId;
  final String clientSecret;

  const ClientSecretData({required this.clientId, required this.clientSecret});
}

/// Application info to register with the server.
class ApplicationInfo {
  final String name;
  final Uri redirectUri;
  final List<String> scopes;
  final Uri? website;

  const ApplicationInfo({
    required this.name,
    required this.redirectUri,
    this.scopes = const [],
    this.website,
  });
}

/// Sealed result type for login operations.
sealed class LoginResult {
  const LoginResult();
}

class LoginSuccess extends LoginResult {
  final UserSecret userSecret;
  final ClientSecretData? clientSecret;
  final User user;

  const LoginSuccess({
    required this.userSecret,
    required this.user,
    this.clientSecret,
  });
}

class LoginNeedsOAuth extends LoginResult {
  /// URL to open in the browser for OAuth authorization.
  final Uri authorizationUrl;

  /// Extra data the adapter needs to complete the flow (e.g., session ID).
  final Map<String, String> extra;

  const LoginNeedsOAuth({required this.authorizationUrl, required this.extra});
}

class LoginFailure extends LoginResult {
  final Object error;
  final StackTrace? stackTrace;

  const LoginFailure(this.error, [this.stackTrace]);
}

/// Two-phase login support.
///
/// Phase 1: [startLogin] returns [LoginNeedsOAuth] with the browser URL.
/// Phase 2: [completeLogin] is called with the callback URI after browser redirect.
abstract mixin class LoginSupport {
  /// [forceLogin] が true なら、ブラウザにそのサーバーのセッションがあっても
  /// ログイン画面から通させる（Mastodon の `force_login=true`・#1109）。
  ///
  /// ⚠ **既定は true**（従来の挙動）。false にできるのは「どのアカウントで承認
  /// されても構わない」場面だけ。⚠ **同じサーバーに 2 つ目のアカウントを足す
  /// ときに false にすると、ブラウザのセッションで 1 つ目が黙って選ばれる。**
  ///
  /// ⚠ Misskey（MiAuth）に相当する概念は無いので無視される。
  Future<LoginResult> startLogin(
    ApplicationInfo application, {
    bool forceLogin = true,
  });
  Future<LoginResult> completeLogin(Uri callbackUri, Map<String, String> extra);
}

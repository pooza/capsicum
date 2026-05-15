/// 通常の HTTP リクエストの接続タイムアウト。
const kNetworkConnectTimeout = Duration(seconds: 5);

/// 通常の HTTP リクエストの受信タイムアウト。
const kNetworkReceiveTimeout = Duration(seconds: 5);

/// capsicum-relay（国外ホスト）向けの接続タイムアウト。
/// 標準より長めに取っているのはコールドスタート・TLS ハンドシェイクの分。
const kPushRelayConnectTimeout = Duration(seconds: 10);

/// capsicum-relay 向けの受信タイムアウト。
const kPushRelayReceiveTimeout = Duration(seconds: 10);

/// APNs / FCM のデバイストークン到着待ち（初回 subscribe 直後）。
const kDeviceTokenWait = Duration(seconds: 10);

/// アプリ全体で使用する定数。
class AppConstants {
  static const appName = 'capsicum';
  static const callbackUrlScheme = 'capsicum';

  /// macOS / Linux / Windows 用: OAuth callback を受ける localhost ポート
  /// (#382 / #489 / #423)。デスクトップ 3 OS でシステムブラウザ + 自前 HTTP
  /// サーバ (`flutter_web_auth_2` の server impl) 経路に統一する。動機は:
  /// - Linux: `desktop_webview_window` の GLX 系 native crash (#489 / #496)
  /// - Windows: MSIX に `flutter_web_auth_2` の native plugin が含まれない (#423)
  /// - macOS: 外部パスワードマネージャ (Bitwarden / 1Password) 連携 + macOS
  ///   Keychain 依存の沼 (#327) 軽減 (#382)
  ///
  /// Mastodon は createApplication 時に redirect_uri を完全一致登録するため、
  /// ポートは固定する必要がある。macOS Mac App Store ビルドは Sandbox 下で
  /// `HttpServer.bind` が成立するために Release.entitlements に
  /// `com.apple.security.network.server` が必要。
  static const localhostOAuthPort = 7099;
  static const localhostOAuthCallbackUrl =
      'http://localhost:$localhostOAuthPort/oauth/callback';

  /// カスタムスキーム経由の OAuth redirect URI。
  /// iOS / Android (ASWebAuthenticationSession / Custom Tabs) で使う。
  /// macOS / Linux / Windows は localhost callback (`localhostOAuthCallbackUrl`)
  /// を使うため、どちらを採用するかは呼び出し側 (login_screen) で判定する。
  static const customSchemeOAuthCallbackUrl = '$callbackUrlScheme://oauth';

  static final websiteUrl = Uri.parse('https://capsicum.shrieker.net');
  static final contactUrl = Uri.parse('https://contact.capsicum.shrieker.net');
  static final communityUrl = Uri.parse('https://pf.korako.me/c/capsicum');
  static final termsUrl = Uri.parse('https://capsicum.shrieker.net/terms');

  // 外部サービス
  static const notestockBaseUrl = 'https://notestock.osa-p.net';
  static final notestockUrl = Uri.parse(notestockBaseUrl);
  static final fediverUrl = Uri.parse('https://f.chomechome.jp');

  // Twemoji CDN
  static const twemojiBaseUrl =
      'https://cdn.jsdelivr.net/gh/twitter/twemoji@latest/assets/72x72';
}

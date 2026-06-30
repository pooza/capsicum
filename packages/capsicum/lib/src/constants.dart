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
  /// iOS (ASWebAuthenticationSession) で使う。
  /// macOS / Linux / Windows は localhost callback (`localhostOAuthCallbackUrl`)
  /// を、Android は App Link (`appLinkOAuthCallbackUrl`) を使うため、
  /// どれを採用するかは呼び出し側 (login_screen) で判定する。
  static const customSchemeOAuthCallbackUrl = '$callbackUrlScheme://oauth';

  /// Android 用: 検証済み App Link (HTTPS) 経由の OAuth redirect URI (#276)。
  /// Android の Custom Tab は `capsicum://` カスタムスキームの redirect を
  /// 取りこぼし、ブラウザ内に bounce する既知の制約がある (Android 12+ の
  /// Verified Links 仕様変更以降に顕著・flutter_web_auth_2 / Custom Tabs 由来)。
  /// `https://relay.capsicum.shrieker.net/oauth/callback` を Digital Asset Links
  /// でアプリに関連付け (autoVerify) すると、OS が確実にアプリへ戻すため bounce が
  /// 根治する。アンカーは relay (capsicum-relay) が配信する
  /// `/.well-known/assetlinks.json`（capsicum.shrieker.net = GitHub Pages は
  /// 古い検証キャッシュが居座るため、キャッシュの無い relay 側に置く）。
  /// host / path は AndroidManifest の autoVerify intent-filter と
  /// `FlutterWebAuth2Options(httpsHost:httpsPath:)` に一致させること。
  static const appLinkOAuthHost = 'relay.capsicum.shrieker.net';
  static const appLinkOAuthPath = '/oauth/callback';
  static const appLinkOAuthCallbackUrl =
      'https://$appLinkOAuthHost$appLinkOAuthPath';

  static final websiteUrl = Uri.parse('https://capsicum.shrieker.net');
  static final presetServersUrl = Uri.parse(
    'https://capsicum.shrieker.net/preset-servers/',
  );
  static final contactUrl = Uri.parse('https://contact.capsicum.shrieker.net');
  static final communityUrl = Uri.parse('https://pf.korako.me/c/capsicum');
  static final termsUrl = Uri.parse('https://capsicum.shrieker.net/terms');

  /// 特定商取引法に基づく表記 (#428 C-1/C-3 確定: 法人名義 有限会社ビーショック)。
  /// capsicum-site の法人名義ページを参照する。最終的な URL の整備 (ページ
  /// 配置 / 法定住所表示 / 連絡先メール) は pooza が capsicum-site 側で行う。
  static final tokushohoUrl = Uri.parse(
    'https://capsicum.shrieker.net/tokushoho',
  );

  /// サポーター（投げ銭）UI のアイコン (#428)。ハートではなく capsicum の
  /// とうがらしを使う。設定エントリ・投げ銭画面・サポーターバッジで共用する。
  static const supporterIconAsset = 'assets/images/capsicum_icon.webp';

  // 外部サービス
  static const notestockBaseUrl = 'https://notestock.osa-p.net';
  static final notestockUrl = Uri.parse(notestockBaseUrl);

  // Twemoji CDN
  static const twemojiBaseUrl =
      'https://cdn.jsdelivr.net/gh/twitter/twemoji@latest/assets/72x72';
}

/// Windows MSIX 配布で使う識別子（#423 / #554）。
///
/// **これらは `pubspec.yaml` の `msix_config` と完全一致が必須**で、ずれると
/// 通知タップ時のアプリ前面化 / payload 受け取りが死ぬ。コード側の single
/// source of truth をここに置き、pubspec 側は文字列のまま手で同期する
/// （pubspec は YAML のため Dart 定数を参照できない）。変更時は必ず両方を
/// 更新すること:
///
/// - [appUserModelId] ↔ `msix_config.identity_name`
/// - [toastActivatorClsid] ↔ `msix_config.toast_activator.clsid`
class WindowsIdentifiers {
  /// アクションセンタ上での通知グルーピングに使う AppUserModelID。
  /// `msix_config.identity_name` と一致させる。
  static const appUserModelId = '9AFBB08E.capsicum';

  /// 通知アクティベータ COM の CLSID。
  /// `msix_config.toast_activator.clsid` と完全一致が必須。
  static const toastActivatorClsid = 'c97e7770-db27-4202-96cc-739a44734e65';
}

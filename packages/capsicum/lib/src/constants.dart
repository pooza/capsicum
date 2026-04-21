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

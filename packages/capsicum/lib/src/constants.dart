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

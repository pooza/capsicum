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

/// サーバーメタデータの鮮度 TTL。バージョン表示 (#774) とモロヘイヤ機能フラグ
/// (#775) は起動時に一度きり probe した値を保持するため、この期間を超えたら
/// 取り直す。ServerMetadataCache の成功キャッシュと AccountManagerNotifier の
/// モロヘイヤ自動再検出で同一の鮮度を共用する (#828)。
const kServerMetadataFreshnessTtl = Duration(hours: 1);

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
  /// macOS / Linux / Windows / Android は localhost callback
  /// (`localhostOAuthCallbackUrl`) を使うため、どちらを採用するかは
  /// 呼び出し側 (login_screen) で判定する。
  static const customSchemeOAuthCallbackUrl = '$callbackUrlScheme://oauth';

  /// Android のループバック OAuth (#276) で、ブラウザの callback ページから
  /// アプリを前面へ戻すための専用カスタムスキーム URL。capsicum の
  /// `localhost` HTTP サーバが認可コードを受領した後、callback ページが
  /// この URL へ遷移して MainActivity を前面に復帰させる（background activity
  /// start 制限を受けない＝フォアグラウンドのブラウザが起動する経路）。
  /// AndroidManifest の MainActivity intent-filter と一致させること。
  static const androidOAuthReturnUrl = 'capsicumauth://complete';

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

  /// Web での支援先 (#893)。ストア IAP が存在しない Linux 版で使う。
  ///
  /// **ストア版（App Store / Google Play / Microsoft Store）では出さない。**
  /// 各ストアがアプリ内から外部決済・寄付へ誘導することを制限しており、IAP と
  /// 並べるとリジェクト要因になりうるため。出し分けは
  /// `supporterPurchaseHasBackend`（＝課金 backend の有無）で行う。
  static final patreonUrl = Uri.parse(
    'https://www.patreon.com/c/u93719112/about',
  );
  static final liberapayUrl = Uri.parse('https://liberapay.com/pooza/');

  /// サポーター（投げ銭）UI のアイコン (#428)。ハートではなく capsicum の
  /// とうがらしを使う。設定エントリ・投げ銭画面・サポーターバッジで共用する。
  static const supporterIconAsset = 'assets/images/capsicum_icon.webp';

  // 外部サービス
  static const notestockBaseUrl = 'https://notestock.osa-p.net';
  static final notestockUrl = Uri.parse(notestockBaseUrl);

  // Twemoji CDN
  static const twemojiBaseUrl =
      'https://cdn.jsdelivr.net/gh/twitter/twemoji@latest/assets/72x72';

  /// Unicode 絵文字文字列から Twemoji CDN の PNG URL を構築する（#903）。
  ///
  /// variation selector は presentation 指定であってグリフを変えないため、
  /// text presentation（U+FE0E）・emoji presentation（U+FE0F）の両方を
  /// codepoint 列から除去する。片方だけ除去すると `.../XXXX-fe0e.png` の
  /// ような存在しないファイル名になり 404 → 生グリフへ fallback してしまう。
  static String twemojiUrl(String emoji) {
    final codepoints = emoji.runes
        .where((r) => r != 0xFE0F && r != 0xFE0E) // strip variation selectors
        .map((r) => r.toRadixString(16))
        .join('-');
    return '$twemojiBaseUrl/$codepoints.png';
  }

  /// リアクションチップ等で絵文字画像を出せないとき、生テキスト（ショートコード
  /// や生グリフ）へ落とす際の文字倍率 (#924)。以前は post_tile=0.7 /
  /// announcement_tile=0.8 / chat_reaction_bar=1.0 と 3 種に散らばっていたので
  /// 1 箇所へ統一した（#852 の横展開で生じた揺れ）。チップに収まるよう本文より
  /// 小さめにしている。
  ///
  /// ⚠ **当て先は「画像を出そうとして出せなかった」経路だけ**（`Image.network`
  /// の `errorBuilder` と、ショートコードの URL を解決できなかったとき）。
  /// Unicode 絵文字をそのまま `Text` で描く経路は fallback ではなく通常表示
  /// なので、隣に並ぶ画像（`height: emojiSize`）と揃うよう等倍で描く。
  /// v1.56 のリリース前レビューで、この統一を通常表示にも当ててしまい
  /// メッセージのリアクションが 3 割縮んでいたのを検出した。
  static const emojiFallbackTextScale = 0.7;
}

/// サーバーが受け付ける入力長の上限 (#1012)。
///
/// ⚠ **client 側で止めないと「失敗しました」の 1 行しか出ない。**超過すると
/// Mastodon / Misskey とも 400 / 422 で断るが、本文は画面に出していないので
/// ユーザーには理由が分からず、書いた文章もそのまま失われる。
///
/// ⚠ **Mastodon と Misskey の小さいほうに合わせる。**アダプタごとに出し分けると
/// ダイアログが backend を知る必要が出る（今はどちらの画面も知らない）。上限に
/// 余裕がある側で数百文字ぶん短くなるだけで、実害はない。
class InputLimits {
  /// 通報の理由。Misskey `report-abuse` の `comment` が 512、Mastodon の
  /// `Report#comment` が 1000。
  static const reportComment = 512;

  /// メディアの説明（ALT）。Misskey `drive/files/update` の `comment` が 512、
  /// Mastodon の `media_attachments.description` はこれより長い。
  static const attachmentDescription = 512;
}

/// 投稿アクションの失敗報告で使う phase タグ (#976)。
///
/// ⚠ **既定値をファイルごとに直書きしない。**#924 で phase を引数化したものの、
/// `post_actions` / `post_tile` / `notification_tile` / `post_touch_action_row`
/// の 4 ファイルが同じリテラルを既定値として抱えたままだった。タグ名を直すと
/// Sentry 上で新旧が混在するので、綴りは 1 箇所で持つ。
class ReactionPhase {
  static const add = 'reaction_add';
  static const remove = 'reaction_remove';
}

/// スタンプ素材（画像オーバーレイ）の受け入れ上限 (#953-2)。
///
/// ⚠ **`k` 付きトップレベル定数はこのファイルへ集める (#976)。**これらだけ
/// `service/sticker_source.dart` に置かれていて、置き場の規約から外れていた。
class StickerLimits {
  /// 受け入れるレスポンスボディの上限バイト数。
  ///
  /// 素材の供給元はサーバー由来の任意 URL（`CustomEmoji.url`）で、**サイズを
  /// こちらで保証できない**。プリセット 3 サーバーの実データで最大が 1MB 弱
  /// （アニメーション webp）なので、桁 1 つぶんの余裕を見て 8MB。カスタム絵文字
  /// は一覧に並べて使うものなので、これを超える素材は運用上そもそも成立しない。
  static const maxBytes = 8 * 1024 * 1024;

  /// デコードする最大高さ（px）。
  ///
  /// スタンプは元画像の高さに対する比率（既定 0.2）で描かれるので、素材が元画像
  /// より高精細でも使い道がない。書き出し先はプリセット上限の 4K 級を想定し、
  /// その 1/2 を上限にしておけば拡大しても粗が出ない。
  static const maxDecodeHeight = 2048;
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

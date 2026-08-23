import 'dart:async';
import 'dart:io';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:go_router/go_router.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../constants.dart';
import '../../model/account.dart';
import '../../model/account_key.dart';
import '../../platform/loopback_oauth_bind.dart';
import '../../platform/platform_info.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../service/account_storage.dart';
import '../../url_helper.dart';
import '../../util/exception_scrub.dart';
import '../../util/login_error.dart';
import '../util/launch_url_toast.dart';
import '../widget/content_parser.dart';

/// OAuth コールバック受信後にシステムブラウザへ表示する完了ページ (#654)。
const _oauthCallbackHtml =
    '<!doctype html><html lang="ja"><head><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width, initial-scale=1">'
    '<title>capsicum</title></head>'
    '<body style="font-family:-apple-system,sans-serif;text-align:center;'
    'padding:48px"><h2>ログイン処理が完了しました</h2>'
    '<p>このタブを閉じて capsicum に戻ってください。</p></body></html>';

/// Android のループバック OAuth (#276) 用 callback ページ。code 受領後、
/// `capsicumauth://complete`（= AppConstants.androidOAuthReturnUrl）へ遷移して
/// MainActivity を前面へ復帰させる。自動遷移が Chrome のジェスチャ制約で
/// 弾かれる端末向けに、タップ用の「capsicum に戻る」ボタンも併置する。
const _oauthCallbackHtmlAndroid =
    '<!doctype html><html lang="ja"><head><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width, initial-scale=1">'
    '<title>capsicum</title>'
    '<script>location.replace("${AppConstants.androidOAuthReturnUrl}");'
    '</script></head>'
    '<body style="font-family:sans-serif;text-align:center;padding:48px">'
    '<h2>ログイン処理が完了しました</h2>'
    '<p>capsicum に戻ります…</p>'
    '<p><a href="${AppConstants.androidOAuthReturnUrl}" style="display:inline-block;'
    'margin-top:16px;padding:12px 24px;background:#d2691e;color:#fff;'
    'border-radius:8px;text-decoration:none">capsicum に戻る</a></p>'
    '</body></html>';

/// macOS の自前 localhost OAuth フロー (#654) で、ユーザーが完了しなかった
/// （ブラウザを閉じた / タイムアウトした）ことを表す。既存の cancel 判定
/// (`e.toString().contains('CANCELED')`) に合流させるため、toString に
/// CANCELED を含める。
class _OAuthCancelledException implements Exception {
  const _OAuthCancelledException();

  @override
  String toString() => 'OAuth flow cancelled (CANCELED)';
}

class LoginScreen extends ConsumerStatefulWidget {
  final String host;
  final BackendType backendType;
  final String? softwareVersion;

  const LoginScreen({
    super.key,
    required this.host,
    required this.backendType,
    this.softwareVersion,
  });

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  /// localhost callback (server impl) 経由で OAuth 認可コードを受けるか
  /// どうか。Linux は `desktop_webview_window` の GLX 系 native crash
  /// (#489 / #496) を、Windows は MSIX に `flutter_web_auth_2` の native
  /// plugin が含まれない制約 (#423) を、いずれも localhost callback で
  /// 回避する。地域名でなく機能ベース命名を採用 (#507)。
  // Linux / Windows / macOS でこの経路に入れる (#382)。挙動はプラット
  // フォームで分かれる:
  // - Linux: desktop_webview_window の GLX 系 native crash 回避 (#489 /
  //   #496)。flutter_web_auth_2 server impl で localhost callback を受ける
  // - Windows: MSIX に flutter_web_auth_2 の native plugin が含まれない
  //   (#423) ため同じく server impl 経路
  // - macOS: flutter_web_auth_2 4.x の macOS 実装は ASWebAuthentication
  //   Session のみで localhost callback の server impl が無い。そこで
  //   FlutterWebAuth2 を使わず `_authenticateViaLocalhostServer` で自前の
  //   HTTP サーバを立てて受ける (#654)。システムブラウザを使うので
  //   Bitwarden / 1Password 拡張が効く (#382)。
  //   （旧実装は #642 で ASWebAuthenticationSession を意図的に CANCELED に
  //   して OOB の手動コード入力に落としていたが、#654 で通常フローへ復帰。）
  // Mac App Store ビルドは Sandbox 下で loopback の listen / bind が成立する
  // ために Release.entitlements に com.apple.security.network.server が必要。
  /// Android もデスクトップと同じく localhost ループバックで OAuth callback を
  /// 受ける (#276)。Android の Custom Tab はカスタムスキーム / 検証済み App Link
  /// いずれの redirect もアプリに引き渡さず bounce するため（flutter_web_auth_2
  /// #187 と同型）、ブラウザの引き渡しに依存しない loopback 方式に切替える。
  /// アプリ内 HTTP サーバへブラウザが直接 HTTP 接続するので確実にコードを取れる。
  /// iOS は ASWebAuthenticationSession でカスタムスキームが確実に戻るため現状維持。
  bool get _useLocalhostCallback => usesLoopbackOAuthCallback;

  /// OAuth redirect URI。デスクトップ / Android は
  /// `localhostOAuthCallbackUrl` (http://localhost:7099/oauth/callback)、
  /// iOS は `capsicum://oauth` カスタムスキーム。
  String get _redirectUri => _useLocalhostCallback
      ? AppConstants.localhostOAuthCallbackUrl
      : AppConstants.customSchemeOAuthCallbackUrl;

  /// `FlutterWebAuth2.authenticate` の `callbackUrlScheme` 引数。
  ///
  /// flutter_web_auth_2 4.1.0 の `_assertCallbackScheme` は Linux / Windows
  /// のみスキップ対象で、それ以外 (macOS 含む) では URI scheme regex
  /// (`^[a-z][a-z\d+.-]*$`) に通らないと `ArgumentError` を投げる。Linux /
  /// Windows は `http://localhost:{port}/{path}` 形式を server impl が
  /// callback URL として直接受けるが、macOS は ASWebAuthenticationSession
  /// 経由のため、ここに渡すのは scheme として valid な文字列でなければ
  /// ならない。
  ///
  /// #654 で macOS は [_authenticateViaLocalhostServer]（システムブラウザ +
  /// 自前 localhost HTTP サーバ）に切り替えたため、このゲッターは
  /// `!Platform.isMacOS` 分岐でのみ消費される。Linux / Windows の localhost
  /// callback では flutter_web_auth_2 の server impl が完全な
  /// `http://localhost:{port}/{path}` URL を期待するため、その URL を返す。
  /// （macOS で本ゲッターが評価された場合のフォールバック値として custom
  /// scheme を残すが、現状 macOS では参照されない。）
  String get _authCallbackUrlScheme {
    if (_useLocalhostCallback && !Platform.isMacOS) {
      return AppConstants.localhostOAuthCallbackUrl;
    }
    return AppConstants.callbackUrlScheme;
  }

  bool _isLoggingIn = false;
  bool _loginCompleted = false;
  String? _error;

  /// ループバック OAuth (#276) の最中に bind した localhost HTTP サーバ。
  /// 認可完了 / タイムアウトで finally が閉じるが、ユーザーが完了前に画面を
  /// 離れる（pop で dispose）と完了 future が 5 分 timeout まで生き残り、
  /// ポート 7099 を掴みっぱなしにして次のログイン試行を塞ぐ。dispose で必ず
  /// 閉じてポートを解放する。
  HttpServer? _oauthServer;

  // Server info
  String? _serverName;
  String? _serverDescription;
  String? _serverThumbnail;
  // 選んだサムネイルがバナー(横長)かアイコン(正方形)かで表示 fit を切り替える。
  // バナーは cover で枠を埋め、アイコンは contain で天地を切らない (#658)。
  BoxFit _serverThumbnailFit = BoxFit.cover;

  bool get _isMastodon => widget.backendType == BackendType.mastodon;

  // 認可完了後の保存に使う provider は initState で掴んでおく (#930)。
  //
  // `ConsumerState.ref` の getter は `context`（＝ `_element!`）を経由するため、
  // **State が dispose 済みだと null check で落ちる**。OAuth / MiAuth は外部
  // ブラウザへ出る往復があり、その間に画面が破棄される（Android がアクティビティ
  // を再生成する等）と、認可自体は成功しているのに `_finishLogin` の入口で
  // 落ちてアカウントが保存されない。#426 では `addAccount` の await 後だけを
  // 守ったため、その手前の `ref.read` 2 箇所が素通しのまま残っていた。
  //
  // これらは app 全体の ProviderScope が持つ長寿命オブジェクトで、この画面が
  // 消えても有効なので、掴んでおけば widget の生死に依存せず保存を完走できる。
  //
  // #930 は `_finishLogin`（保存経路）だけを守ったが、**往復の後に ref を触る形は
  // 自己回復経路にも 2 箇所あった**（`?error=` の error_retry / cancel の
  // silent_retry）。どちらも `try` の中なので StateError が catch に握られ、
  // 「クレデンシャルを消さないまま `_login(isRetry: true)` へ進む」＝#620 / #824 の
  // 自己回復が黙って無効化される形だった。**この画面で往復後に ref を使わない**
  // という不変条件にして塞いである (#955)。
  late final AccountStorage _accountStorage;
  late final AccountManagerNotifier _accountManager;

  @override
  void initState() {
    super.initState();
    _accountStorage = ref.read(accountStorageProvider);
    _accountManager = ref.read(accountManagerProvider.notifier);
    _fetchServerInfo();
  }

  @override
  void dispose() {
    // 完了前に画面を離れた場合に localhost OAuth サーバを閉じてポート 7099 を
    // 解放する（掴みっぱなしだと次のログイン試行が「ポート占有」で塞がれる・#276）。
    unawaited(_oauthServer?.close(force: true));
    _oauthServer = null;
    super.dispose();
  }

  Future<void> _fetchServerInfo() async {
    try {
      final dio = Dio();
      if (_isMastodon) {
        final res = await dio.get('https://${widget.host}/api/v2/instance');
        if (res.statusCode == 200) {
          final data = res.data as Map<String, dynamic>;
          if (mounted) {
            setState(() {
              _serverName = data['title'] as String?;
              _serverDescription = _stripHtml(
                data['description'] as String? ?? '',
              );
              final thumbnail = data['thumbnail'] as Map<String, dynamic>?;
              // thumbnail (バナー) が未設定だと Mastodon はバンドルのデフォルト
              // preview 画像を返すので、それは「指定なし」とみなして PWA アイコン
              // (icon[] の 192px / 最大) にフォールバックする。/api/v2/instance に
              // マスコットは無い (#658)。
              final rawThumb = thumbnail?['url'] as String?;
              final customThumb = _isDefaultMastodonThumbnail(rawThumb)
                  ? null
                  : rawThumb;
              final picked = _pickImageUrl([
                (customThumb, true),
                (_mastodonIcon192(data['icon']), false),
              ]);
              _serverThumbnail = picked?.url;
              _serverThumbnailFit = (picked?.wide ?? true)
                  ? BoxFit.cover
                  : BoxFit.contain;
            });
          }
        }
      } else {
        final res = await dio.post('https://${widget.host}/api/meta', data: {});
        if (res.statusCode == 200) {
          final data = res.data as Map<String, dynamic>;
          if (mounted) {
            setState(() {
              _serverName = data['name'] as String?;
              _serverDescription = _stripHtml(
                data['description'] as String? ?? '',
              );
              // 背景 → バナー → app192Icon → favicon の順で無画像サーバーを
              // 減らす。相対パスは host を前置 (#658)。
              // mascotImageUrl は除外する: ほぼ全 Misskey でデフォルト値
              // `/assets/ai.png` を返すが、その実体はサーバールートに無く 404
              // するため、有効な iconUrl があっても空表示になってしまう
              // (#658 のリグレッション)。AI-chan マスコットはサーバーのロゴ
              // でもないので、候補から外すのが正しい。
              final picked = _pickImageUrl([
                (data['backgroundImageUrl'] as String?, true),
                (data['bannerUrl'] as String?, true),
                (data['app192IconUrl'] as String?, false),
                (data['iconUrl'] as String?, false),
              ]);
              _serverThumbnail = picked?.url;
              _serverThumbnailFit = (picked?.wide ?? true)
                  ? BoxFit.cover
                  : BoxFit.contain;
            });
          }
        }
      }
    } catch (_) {
      // Server info is optional; ignore errors.
    }
  }

  String _stripHtml(String html) => stripHtml(html).trim();

  /// 候補を先頭から走査し、最初の非空 URL を絶対化して返す (#658)。各候補は
  /// `(url, wide)` で、`wide` はバナー(横長)系なら true・アイコン(正方形)系
  /// なら false。戻り値の `wide` で表示 fit を切り替える。
  ({String url, bool wide})? _pickImageUrl(List<(String?, bool)> candidates) {
    for (final (raw, wide) in candidates) {
      final normalized = _absoluteUrl(raw);
      if (normalized != null) return (url: normalized, wide: wide);
    }
    return null;
  }

  /// 相対パス (`/assets/ai.png` 等) を `https://host` 前置で絶対化。
  /// null / 空文字は null に倒す。
  String? _absoluteUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('/')) return 'https://${widget.host}$url';
    return url;
  }

  /// Mastodon の thumbnail が未設定時のバンドルデフォルト preview 画像かを
  /// 判定する (#658)。デフォルトは `/packs/.../preview-<hash>.png` のように
  /// webpack/Vite の bundle assets 配下に preview ファイル名で置かれる。管理者が
  /// アップロードしたカスタム thumbnail は `/site_uploads/` 配下なので preview
  /// ファイル名にはならず、ここで false になる。
  bool _isDefaultMastodonThumbnail(String? url) {
    if (url == null || url.isEmpty) return false;
    final path = Uri.tryParse(url)?.path ?? url;
    final base = path.split('/').last;
    return path.contains('/packs/') && base.startsWith('preview');
  }

  /// Mastodon `/api/v2/instance` の `icon[]`（PWA アイコン配列）から 192px を
  /// 優先で選ぶ。無ければ最大サイズ。マスコットは API に無いためこれで代替 (#658)。
  String? _mastodonIcon192(dynamic icons) {
    if (icons is! List) return null;
    String? best;
    int bestWidth = 0;
    for (final entry in icons) {
      if (entry is! Map) continue;
      final src = entry['src'] as String?;
      if (src == null || src.isEmpty) continue;
      final width =
          int.tryParse((entry['size'] as String?)?.split('x').first ?? '') ?? 0;
      if (width == 192) return src;
      if (width > bestWidth) {
        bestWidth = width;
        best = src;
      }
    }
    return best;
  }

  void _logLoginStep(String step, {Map<String, Object?>? data}) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        category: 'login',
        message: step,
        level: SentryLevel.info,
        data: {
          'host': widget.host,
          'backend': widget.backendType.name,
          ...?data,
        },
      ),
    );
  }

  /// localhost callback 用のポート ([AppConstants.localhostOAuthPort]) が
  /// 別プロセスに占有されているかを試し、占有時は専用エラー文を返す。
  /// 空いていれば null を返す。TOCTOU はあるが、flutter_web_auth_2 側で
  /// EADDRINUSE を握って authorization code を取り逃がす UX 劣化を
  /// 識別可能な error に置き換えるための実用的な防御 (#503)。
  Future<String?> _checkOAuthPortAvailability() async {
    try {
      final socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        AppConstants.localhostOAuthPort,
      );
      await socket.close();
      return null;
    } on SocketException catch (e) {
      _logLoginStep(
        'oauth_port.occupied',
        data: {
          'port': AppConstants.localhostOAuthPort,
          'error': e.osError?.message ?? e.message,
        },
      );
      return 'OAuth コールバック用ポート ${AppConstants.localhostOAuthPort} が'
          '他プロセスに占有されています。占有中のアプリを閉じてから再試行してください。';
    }
  }

  /// macOS の OAuth コールバックを自前 localhost HTTP サーバで受ける (#654)。
  ///
  /// [authorizationUrl] をシステムブラウザ (url_launcher) で開き、
  /// `http://localhost:7099/oauth/callback?code=...` へのリダイレクトを自前の
  /// [HttpServer] で受けて認可コードを取り出す。flutter_web_auth_2 の macOS
  /// 実装 (ASWebAuthenticationSession・localhost server impl 無し) に依存せず、
  /// Linux / Windows の server impl 相当を自前化したもの。システムブラウザを
  /// 使うので Bitwarden / 1Password 等の拡張が効く (#382)。OOB の手動コード
  /// 入力を廃止する。
  ///
  /// loopback の listen には Release.entitlements の
  /// `com.apple.security.network.server` が必要。ポート占有は呼び出し前に
  /// [_checkOAuthPortAvailability] で弾く前提。
  /// [expectedState] を渡すと、callback の `state` が一致したリクエストだけを
  /// 認可応答として受け付ける (#790)。Mastodon は認可/エラー応答に state を
  /// エコーするため、同一端末の別アプリ/ページからのコード注入・DoS レースを
  /// 受け流せる。Misskey MiAuth は state を使わず（`?session=` のみ・completeLogin
  /// が inbound を無視するため非注入）null を渡して従来どおり受ける。
  Future<String> _authenticateViaLocalhostServer(
    Uri authorizationUrl, {
    String? expectedState,
  }) async {
    // 前回のログイン試行のサーバが残っていると同一ポートに再 bind できず
    // EADDRINUSE (errno98) になる (#813)。bind 前に必ず閉じてポートを解放する。
    final previous = _oauthServer;
    if (previous != null) {
      _oauthServer = null;
      await previous.close(force: true);
    }
    // 127.0.0.1 で listen する。redirect_uri は `localhost` だが、macOS の
    // getaddrinfo は ::1 と 127.0.0.1 の両方を返し、ブラウザは Happy Eyeballs
    // で IPv4 にフォールバックするため loopbackIPv4 で受けられる。固定ポートは
    // 登録済み redirect_uri (http://localhost:7099/oauth/callback) と一致させる
    // 必要があり、Doorkeeper は port まで厳密一致するためエフェメラル化できない。
    // 直前クローズの解放遅延など一時的な EADDRINUSE はリトライで吸収し、使い切れば
    // LoopbackPortOccupiedException を投げて呼び出し側で友好エラーに昇格させる。
    final server = await bindLoopbackOAuthServer(
      AppConstants.localhostOAuthPort,
    );
    _oauthServer = server;
    _logLoginStep('oauth_server.listening');
    try {
      final launched = await launchUrlSafely(
        authorizationUrl,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw StateError('failed to launch system browser for OAuth');
      }

      // redirect_uri のパス (例: /oauth/callback)。コールバック判定はクエリ名
      // ではなくこのパスで行う。Mastodon は `?code=` / `?error=`、Misskey
      // MiAuth は `?session=` を付けて戻るため、`code`/`error` 限定だと Misskey
      // の session を取り逃して 5 分ハングしていた (内部ベータ 1.31.0+88 で実証)。
      final callbackPath = Uri.parse(
        AppConstants.localhostOAuthCallbackUrl,
      ).path;
      final completer = Completer<Uri>();
      final subscription = server.listen((request) async {
        // dispose() が受信処理の最中に server.close(force:true) すると
        // response の write/close が StateError/HttpException を投げ、未捕捉
        // async エラー（zone→Sentry ノイズ）になる。サーバ終了中の失敗は
        // 無害なので握りつぶす。
        try {
          final uri = request.uri;
          // コールバックパスへの非空クエリ付きリクエストを認可リダイレクトと
          // みなす。favicon 等パスの異なるノイズ要求は 404 で受け流す。
          final isCallback =
              uri.path == callbackPath && uri.queryParameters.isNotEmpty;
          // state 照合 (#790): expectedState 指定時（Mastodon）は inbound state が
          // 一致したものだけを認可応答として受け付け、別アプリ/別ページからの
          // コード注入・DoS レースは 404 で受け流して本物の callback を待ち続ける。
          // expectedState が null（Misskey MiAuth）なら従来どおり最初の callback。
          final stateOk =
              expectedState == null ||
              uri.queryParameters['state'] == expectedState;
          final accept = isCallback && stateOk;
          request.response
            ..statusCode = accept ? HttpStatus.ok : HttpStatus.notFound
            ..headers.contentType = ContentType.html
            ..write(
              accept
                  ? (oauthCallbackNeedsAppReturn
                        ? _oauthCallbackHtmlAndroid
                        : _oauthCallbackHtml)
                  : '<!doctype html>',
            );
          await request.response.close();
          if (accept && !completer.isCompleted) {
            completer.complete(uri);
          }
        } catch (_) {
          // サーバ終了中のレスポンス書き込み失敗等。認可コードは completer
          // で受領済みか、未受領なら timeout/cancel 経路に合流するため無視。
        }
      });

      try {
        final callbackUri = await completer.future.timeout(
          const Duration(minutes: 5),
        );
        _logLoginStep('oauth_server.callback_received');
        // completeLogin は code クエリだけ参照するので、redirect_uri と同じ
        // localhost URL に受信クエリを載せ替えて返す。
        return Uri.parse(
          AppConstants.localhostOAuthCallbackUrl,
        ).replace(queryParameters: callbackUri.queryParameters).toString();
      } on TimeoutException {
        // 5 分以内に戻らなかった（ブラウザを閉じた等）。既存の cancel
        // ハンドリングに合流させる。
        _logLoginStep('oauth_server.timeout');
        throw const _OAuthCancelledException();
      } finally {
        await subscription.cancel();
      }
    } finally {
      await server.close(force: true);
      if (identical(_oauthServer, server)) _oauthServer = null;
    }
  }

  Future<void> _login({bool isRetry = false}) async {
    if (_loginCompleted) return;
    // 進行中の多重起動を弾く。二重タップ等で _authenticateViaLocalhostServer が
    // 同一ポート 7099 に二重 bind すると EADDRINUSE (errno98) を招く (#813)。
    // retry 経路 (isRetry:true) は進行中の同一フローからの続行なので通す。
    if (_isLoggingIn && !isRetry) return;
    setState(() {
      _isLoggingIn = true;
      _error = null;
    });

    DecentralizedBackendAdapter? adapter;
    Map<String, String> oauthExtra = {};
    var reachedAuthenticate = false;
    var authenticateReturned = false;
    var fallbackAttempted = false;
    var usedCachedCreds = false;

    _logLoginStep('login.start', data: {'isRetry': isRetry});

    try {
      adapter = await widget.backendType.createAdapter(widget.host);
      final loginSupport = adapter as LoginSupport;

      // Reuse cached client credentials to avoid calling POST /api/v1/apps
      // (rate-limit prone). Check: 1) existing accounts, 2) host-level storage.
      // isRetry=true は #620 silent recovery で cache を破棄した直後の経路。
      // ここで再び cache を読むと無限ループになるので skip して fresh
      // registration を強制する。
      if (adapter is MastodonAdapter && !isRetry) {
        final accounts = ref.read(accountManagerProvider).accounts;
        final existing = accounts
            .where((a) => a.key.host == widget.host && a.clientSecret != null)
            .firstOrNull;
        // Android (#276): 既存アカウントの cached client は旧 `capsicum://oauth`
        // で登録された可能性があり、localhost redirect へ移行した今これを再利用
        // すると Mastodon が /oauth/authorize を invalid_redirect_uri で蹴る。
        // その場合 localhost へ redirect されず（redirect が無いので `?error=`
        // 自己回復も発火せず）loopback が 5 分ハングする。account-scoped client は
        // 登録時の redirect_uri を保持しないため Android では使わず、redirect_uri
        // で scope された host 保存（getHostClientCredentials）か fresh 登録に
        // 委ねる。移行後の初回ログインで localhost client が host 保存されるので、
        // 再登録は host あたり 1 回で済む。
        if (existing != null && canReuseAccountScopedOAuthClient) {
          adapter.setCachedClientCredentials(existing.clientSecret);
          usedCachedCreds = true;
        } else {
          final storage = ref.read(accountStorageProvider);
          final hostCreds = await storage.getHostClientCredentials(
            widget.host,
            _redirectUri,
          );
          if (hostCreds != null) {
            adapter.setCachedClientCredentials(hostCreds);
            usedCachedCreds = true;
          }
        }
      }

      final application = ApplicationInfo(
        name: AppConstants.appName,
        redirectUri: Uri.parse(_redirectUri),
        scopes: const ['read', 'write', 'follow', 'push'],
        website: AppConstants.websiteUrl,
      );

      _logLoginStep('startLogin.begin');
      final startResult = await loginSupport.startLogin(application);
      _logLoginStep(
        'startLogin.end',
        data: {'result': startResult.runtimeType.toString()},
      );

      if (startResult is LoginNeedsOAuth) {
        oauthExtra = startResult.extra;

        // 新規登録した OAuth アプリを「登録成功直後」に host 保存する (#824)。
        // 従来は _finishLogin（トークン交換完了後）まで保存せず、以降の OAuth を
        // cancel / timeout / `?error=` で中断すると登録済みアプリが捨てられ、次回
        // また `POST /api/v1/apps` で 1 枠消費していた（5/30min の登録上限を正規
        // クライアントの失敗連続で食い潰す＝「正しい資格情報でもログイン不能」）。
        // ここで保存すれば以降は cached creds を使い回し、被害が host あたり実質
        // 1 回に収まる。cached creds 再利用時 (usedCachedCreds) は既に保存済みの
        // ため二重書きしない。保存失敗はログインを止めず best-effort。
        if (_isMastodon && !usedCachedCreds) {
          final clientId = startResult.extra['client_id'];
          final clientSecret = startResult.extra['client_secret'];
          if (clientId != null && clientSecret != null) {
            try {
              await ref
                  .read(accountStorageProvider)
                  .saveHostClientCredentials(
                    widget.host,
                    clientId,
                    clientSecret,
                    _redirectUri,
                  );
            } catch (e) {
              _logLoginStep(
                'host_creds.bank_failed',
                data: {'type': e.runtimeType.toString()},
              );
            }
          }
        }

        // Open browser and wait for callback redirect.
        assert(() {
          debugPrint('capsicum: OAuth URL: ${startResult.authorizationUrl}');
          return true;
        }());
        _logLoginStep('authenticate.begin');
        reachedAuthenticate = true;
        // flutter_web_auth_2 の server impl (Linux / Windows) は内部で 7099 に
        // bind するが、EADDRINUSE を握って authorization code を取り逃がすだけで
        // ポート競合と判別できない (#503)。authenticate 直前に短時間
        // ServerSocket.bind を試して占有を専用エラーに昇格させる。self-hosted
        // 経路 (Android / macOS) は _authenticateViaLocalhostServer 側が
        // 旧サーバ close + bind リトライ + 友好エラーで自己完結するため、ここで
        // 二重 bind して自己 TOCTOU を招かないよう precheck を掛けない (#813)。
        if (_useLocalhostCallback && !usesSelfHostedOAuthLoopbackServer) {
          final portError = await _checkOAuthPortAvailability();
          if (portError != null) {
            if (mounted) setState(() => _error = portError);
            return;
          }
        }
        final String resultUrl;
        if (usesSelfHostedOAuthLoopbackServer) {
          // macOS (#654): flutter_web_auth_2 に localhost server impl が無い。
          // Android (#276): Custom Tab がカスタムスキーム / 検証済み App Link の
          // どちらの redirect もアプリに引き渡さず bounce する (#187 同型)。
          // 両者ともシステムブラウザ + 自前 localhost HTTP サーバで code を受ける
          // loopback 方式に統一する（ブラウザの引き渡しに依存しない）。Android は
          // コード受領後、callback ページが androidOAuthReturnUrl へ遷移して
          // アプリを前面へ復帰させる（_authenticateViaLocalhostServer 内で処理）。
          resultUrl = await _authenticateViaLocalhostServer(
            startResult.authorizationUrl,
            // Mastodon は startLogin で state を発行する。Misskey MiAuth は
            // 発行しない（extra に 'state' 無し→null）ため従来どおり受ける。
            expectedState: startResult.extra['state'],
          );
        } else {
          // localhost callback では `desktop_webview_window` の GLX 系 native
          // crash (#489 / #496) を回避するため useWebview: false で
          // システムブラウザ + 自前 HTTP サーバ (flutter_web_auth_2 server impl)
          // で受ける。callbackUrlScheme は server impl では完全な
          // http://localhost:{port}/{path} URL を期待する仕様 (flutter_web_auth_2
          // 4.1.0 の server.dart 参照)。
          resultUrl = await FlutterWebAuth2.authenticate(
            url: startResult.authorizationUrl.toString(),
            callbackUrlScheme: _authCallbackUrlScheme,
            options: _useLocalhostCallback
                ? const FlutterWebAuth2Options(useWebview: false)
                : const FlutterWebAuth2Options(preferEphemeral: true),
          );
        }
        authenticateReturned = true;
        _logLoginStep('authenticate.end');

        final callbackUri = Uri.parse(resultUrl);

        // 認可サーバが `code` ではなく `?error=` でリダイレクトしてきたケース
        // (内部ベータ 1.31.0+88 で Mastodon が観測)。キャッシュ済みクライアント
        // 資格情報が古いスコープ等で登録されていると、再ログイン時に
        // `invalid_scope` 等で即リダイレクトされ、従来は generic な
        // 「No code in callback」で失敗していた。cache 由来かつ初回に限り、
        // cache を破棄して POST /api/v1/apps からやり直す (#620 と同型の自己回復)。
        // Misskey MiAuth は `?session=` で戻り error も code も無いため対象外。
        //
        // ただし delete+再登録は **cache が stale なとき**にだけ意味がある (#824)。
        // `access_denied`（ユーザーが拒否）や `temporarily_unavailable`・レート制限
        // 由来の error では cache は正常なのに 1 枠を無駄に消費し、登録上限の枯渇を
        // 早める。stale を示す error コードに限って自己回復する。
        if (callbackUri.queryParameters.containsKey('error') &&
            !callbackUri.queryParameters.containsKey('code')) {
          final oauthError = callbackUri.queryParameters['error'];
          _logLoginStep(
            'authenticate.error_redirect',
            data: {'error': oauthError, 'usedCachedCreds': usedCachedCreds},
          );
          // cache 済みクライアントが「古いスコープ / 無効なクライアント / 未登録
          // redirect_uri」で登録されていることを示す error のみ再登録に値する。
          const staleCredsErrors = {
            'invalid_scope',
            'invalid_client',
            'invalid_redirect_uri',
          };
          if (usedCachedCreds &&
              _isMastodon &&
              !isRetry &&
              staleCredsErrors.contains(oauthError)) {
            _logLoginStep('login.error_retry.begin');
            try {
              // 外部ブラウザ往復の**後**なので `ref` は使わない。往復中に State が
              // 破棄されていると `ref.read` が StateError を投げ、直下の catch に
              // 握られてクレデンシャル破棄がスキップされる（＝#620 / #824 の自己
              // 回復が働かない）。initState で掴んだ長寿命の参照を使う (#955)。
              await _accountStorage.deleteHostClientCredentials(widget.host);
            } catch (clearErr) {
              _logLoginStep(
                'login.error_retry.clear_failed',
                data: {'type': clearErr.runtimeType.toString()},
              );
            }
            await _login(isRetry: true);
            _logLoginStep(
              'login.error_retry.end',
              data: {'completed': _loginCompleted},
            );
            return;
          }
          if (mounted) {
            setState(
              () => _error =
                  'サーバーが認証を拒否しました（$oauthError）。'
                  'しばらく時間をおいて再度お試しください。',
            );
          }
          return;
        }

        _logLoginStep(
          'completeLogin.begin',
          data: {
            'hasCode': callbackUri.queryParameters.containsKey('code'),
            'scheme': callbackUri.scheme,
          },
        );
        final completeResult = await loginSupport.completeLogin(
          callbackUri,
          startResult.extra,
        );
        _logLoginStep(
          'completeLogin.end',
          data: {'result': completeResult.runtimeType.toString()},
        );

        if (completeResult is LoginSuccess) {
          await _finishLogin(adapter, completeResult);
        } else if (completeResult is LoginFailure) {
          debugPrint('Login failed: ${completeResult.error}');
          // MiAuth ポーリング枯渇 (#276): 承認がまだ反映されていない／ユーザーが
          // 拒否した場合は Misskey が `{ok:false}` を返し続け、poll が尽きて
          // MisskeyMiAuthPending で失敗する。ジェネリック失敗と区別し、再試行を
          // 促す文言にする（Sentry は例外クラスで既に区別可能だが、枯渇率を
          // 追えるよう breadcrumb も残す）。
          final pollExhausted = completeResult.error is MisskeyMiAuthPending;
          if (pollExhausted) {
            _logLoginStep('completeLogin.miauth_poll_exhausted');
          }
          Sentry.captureException(
            scrubException(completeResult.error),
            stackTrace: completeResult.stackTrace,
          );
          if (mounted) {
            setState(
              () => _error = pollExhausted
                  ? '承認がまだ反映されていないか、承認が完了していません。'
                        'もう一度お試しください。'
                  : 'ログインに失敗しました',
            );
          }
        }
      } else if (startResult is LoginFailure) {
        debugPrint('Login start failed: ${startResult.error}');
        Sentry.captureException(
          scrubException(startResult.error),
          stackTrace: startResult.stackTrace,
        );
        final errorMsg = startResult.error;
        if (mounted) {
          setState(
            () => _error = errorMsg is String ? errorMsg : 'ログインの開始に失敗しました',
          );
        }
      }
    } catch (e, st) {
      // 自前 loopback サーバの bind がリトライを使い切った (#813)。ポート占有を
      // ユーザーに伝わる文言へ昇格させ、cancel/フォールバック経路には流さない
      // （OOB 手貼り等に落ちる前に原因を提示する）。
      if (e is LoopbackPortOccupiedException) {
        // 最後の bind エラーの errno / OS メッセージを取り出す（非 PII・#859）。
        // EADDRINUSE(errno98) か EACCES 等かで対策が正反対（リトライ窓の延長か
        // UX 手当てか）になるため、計装で切り分け材料を回収する。
        final lastError = e.lastError;
        final osError = lastError is SocketException ? lastError.osError : null;
        final errno = osError?.errorCode;
        final osMessage = osError?.message ?? lastError?.toString();
        _logLoginStep(
          'oauth_server.bind_exhausted',
          data: {'port': e.port, 'errno': ?errno, 'os_error': ?osMessage},
        );
        // #813 で堅牢化した bind リトライが枯渇した実頻度を計測する (#822)。UX は
        // 友好エラーで良好だが、breadcrumb だけでは後続の captured event に
        // 相乗りしない限り送られず、ポート占有でログインがブロックされる頻度が
        // 見えない。warning を 1 発上げる。生 URL / トークンは載せず、既存 scrub
        // 方針どおり host / backend / port の非 PII タグのみ。
        // 計測のために友好エラー表示 (下) を巻き添えにしない。restore 系の
        // captureMessage (account_manager_provider) と同じく try/catch で保護
        // する (#828 parity)。Sentry は初期化済みで同期 throw しない設計だが、
        // 観測のための計装が UX 経路を壊さないことを構造で担保する。
        try {
          Sentry.captureMessage(
            'oauth_server.bind_exhausted (port=${e.port})',
            level: SentryLevel.warning,
            withScope: (scope) {
              scope.setTag('service', 'oauth_loopback');
              scope.setTag('login.host', widget.host);
              scope.setTag('login.backend', widget.backendType.name);
              scope.setTag('oauth.port', e.port.toString());
              // 最後の bind エラーの errno / OS メッセージ（非 PII・#859）。
              // EADDRINUSE(98) か EACCES 等かで対策が分かれるため切り分け用に載せる。
              if (errno != null) scope.setTag('oauth.errno', errno.toString());
              if (osMessage != null) scope.setTag('oauth.os_error', osMessage);
              // ポートは固定・errno はタグでの切り分けに留め、文面ゆらぎで分裂
              // させず 1 グループに集約する（#859: fingerprint は現状どおり）。
              scope.fingerprint = ['oauth_server.bind_exhausted'];
            },
          );
        } catch (_) {
          // 計装失敗は握りつぶす（友好エラー表示を優先）。
        }
        if (mounted) {
          setState(
            () => _error =
                'OAuth コールバック用ポート ${e.port} が他プロセスに占有されています。'
                '占有中のアプリを閉じてから再試行してください。',
          );
        }
        return;
      }
      final isCancelled =
          e.toString().contains('CANCELED') ||
          e.toString().contains('cancelled');
      _logLoginStep(
        'login.exception',
        data: {
          'type': e.runtimeType.toString(),
          'isCancelled': isCancelled,
          'reachedAuthenticate': reachedAuthenticate,
          'authenticateReturned': authenticateReturned,
          'usedCachedCreds': usedCachedCreds,
          'isRetry': isRetry,
        },
      );

      // #620 silent recovery: cached client_id が古い redirect_uri (例:
      // capsicum://oauth) で登録されていると、新版 (http://localhost:7099/
      // oauth/callback) で /oauth/authorize を叩いた瞬間に Mastodon が
      // 「invalid_redirect_uri」エラーページを返し、ユーザーには CANCEL
      // としてしか観測できない。cache 由来かつ初回の cancel に限って、
      // cache を破棄して POST /api/v1/apps からやり直す。retry 後の cancel
      // は usedCachedCreds=false (isRetry=true 経路は cache 読みを skip)
      // なのでループしない。
      if (isCancelled &&
          usedCachedCreds &&
          _isMastodon &&
          !isRetry &&
          reachedAuthenticate &&
          !authenticateReturned) {
        _logLoginStep('login.silent_retry.begin');
        try {
          // error_retry と同じ理由で `ref` を使わない (#955)。この経路は
          // 「ブラウザ往復が cancel として観測された」後なので、Android が
          // 往復中にアクティビティを再生成していた場合に State が生きていない。
          await _accountStorage.deleteHostClientCredentials(widget.host);
        } catch (clearErr) {
          _logLoginStep(
            'login.silent_retry.clear_failed',
            data: {'type': clearErr.runtimeType.toString()},
          );
        }
        await _login(isRetry: true);
        _logLoginStep(
          'login.silent_retry.end',
          data: {'completed': _loginCompleted},
        );
        return;
      }

      // User cancelled the browser or redirect failed.
      var fallbackSucceeded = false;
      if (!_loginCompleted && adapter != null && oauthExtra.isNotEmpty) {
        fallbackAttempted = true;
        // For MiAuth, the session may already be approved on the server
        // even when the redirect back to the app fails (Android 12+ Custom Tab
        // issues, etc.). Try completing the login as a fallback.
        if (!_isMastodon) {
          _logLoginStep('fallback.miauth.begin');
          final ok = await _tryMiAuthFallback(adapter, oauthExtra);
          _logLoginStep('fallback.miauth.end', data: {'ok': ok});
          if (ok) {
            fallbackSucceeded = true;
            return;
          }
        }

        // For Mastodon OAuth, prompt the user to manually enter the
        // authorization code from the browser URL bar.
        if (_isMastodon) {
          _logLoginStep('fallback.mastodon.begin');
          final ok = await _tryManualCodeFallback(
            adapter as LoginSupport,
            oauthExtra,
          );
          _logLoginStep('fallback.mastodon.end', data: {'ok': ok});
          if (ok) {
            fallbackSucceeded = true;
            return;
          }
        }
      }

      if (isCancelled) {
        // User cancelled (or redirect failed). Only report to Sentry when a
        // fallback was attempted and also failed — that is the #276 signal
        // we actually want to investigate.
        if (fallbackAttempted && !fallbackSucceeded) {
          Sentry.captureException(
            scrubException(e),
            stackTrace: st,
            withScope: (scope) {
              scope.setTag('login.stage', 'fallback_failed_after_cancel');
              scope.setTag('login.backend', widget.backendType.name);
              scope.setTag(
                'login.reachedAuthenticate',
                reachedAuthenticate.toString(),
              );
            },
          );
        }
      } else {
        // #644: キャンセル以外の例外を例外種別で分類し、文言を出し分ける。
        // 旧実装はすべて「通信に失敗しました」とし、Keychain 保存失敗
        // (#643) 等を通信エラーと誤診させていた。
        final failure = classifyLoginFailure(e);
        debugLogException('Login error (${failure.kind.name})', e);
        Sentry.captureException(
          scrubException(e),
          stackTrace: st,
          withScope: (scope) =>
              scope.setTag('login.failure_kind', failure.kind.name),
        );
        if (mounted) setState(() => _error = failure.message);
      }
    } finally {
      if (mounted) setState(() => _isLoggingIn = false);
    }
  }

  /// Attempt to complete MiAuth login when the browser redirect failed.
  /// MiAuth sessions can be checked by session ID alone, so the callback
  /// URL parameters are not needed.
  Future<bool> _tryMiAuthFallback(
    DecentralizedBackendAdapter adapter,
    Map<String, String> extra,
  ) async {
    try {
      final loginSupport = adapter as LoginSupport;
      final result = await loginSupport.completeLogin(Uri(), extra);
      _logLoginStep(
        'fallback.miauth.completeLogin',
        data: {'result': result.runtimeType.toString()},
      );
      if (result is LoginSuccess) {
        await _finishLogin(adapter, result);
        return true;
      }
    } catch (e) {
      _logLoginStep(
        'fallback.miauth.exception',
        data: {'type': e.runtimeType.toString()},
      );
      // Fallback failed — let the original error handling proceed.
    }
    return false;
  }

  /// Prompt the user to manually paste the authorization code when the
  /// browser redirect back to the app failed (Mastodon OAuth only).
  ///
  /// Opens a new browser with `urn:ietf:wg:oauth:2.0:oob` as the redirect
  /// URI so that Mastodon displays the authorization code on screen instead
  /// of redirecting to the custom scheme.
  Future<bool> _tryManualCodeFallback(
    LoginSupport loginSupport,
    Map<String, String> extra,
  ) async {
    if (!mounted) return false;

    const oobRedirect = 'urn:ietf:wg:oauth:2.0:oob';
    final adapter = loginSupport as MastodonAdapter;

    // Show the dialog immediately; re-register the app (to add OOB support)
    // only when the user taps the button.
    var clientId = extra['client_id']!;
    var clientSecret = extra['client_secret']!;
    var oobReady = false;

    Future<void> ensureOobRegistration() async {
      if (oobReady) return;
      try {
        final app = await adapter.client.createApplication(
          clientName: AppConstants.appName,
          redirectUris: '$_redirectUri\n$oobRedirect',
          scopes: extra['scopes']!,
          website: AppConstants.websiteUrl.toString(),
        );
        clientId = app.clientId!;
        clientSecret = app.clientSecret!;
        adapter.setCachedClientCredentials(
          ClientSecretData(clientId: clientId, clientSecret: clientSecret),
        );
        final storage = ref.read(accountStorageProvider);
        // OOB 再登録は `$_redirectUri\n$oobRedirect` の両方を登録するので、
        // 通常フローの redirect_uri (_redirectUri) でも再利用可能。
        await storage.saveHostClientCredentials(
          widget.host,
          clientId,
          clientSecret,
          _redirectUri,
        );
      } catch (e) {
        debugLogException('capsicum: OOB app re-registration failed', e);
      }
      oobReady = true;
    }

    final code = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final controller = TextEditingController();
        var isLoading = false;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: const Text('認証コードの入力'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'ブラウザから戻れない場合は、スワイプで'
                      '戻ってください。多くの場合、認証は完了'
                      'しています。\n\n'
                      'ログインできない場合は、下のボタンで'
                      '認証コードを取得して貼り付けてください。',
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: isLoading
                          ? const Center(
                              child: SizedBox(
                                height: 24,
                                width: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : OutlinedButton.icon(
                              onPressed: () async {
                                setDialogState(() => isLoading = true);
                                await ensureOobRegistration();
                                if (!dialogContext.mounted) return;
                                setDialogState(() => isLoading = false);
                                final oobUrl =
                                    Uri.https(widget.host, '/oauth/authorize', {
                                      'response_type': 'code',
                                      'client_id': clientId,
                                      'redirect_uri': oobRedirect,
                                      'scope': extra['scopes']!,
                                      'force_login': 'true',
                                    });
                                // 失敗時の SnackBar は共通ヘルパーへ寄せた
                                // (#976)。
                                await launchUrlOrToast(
                                  dialogContext,
                                  oobUrl,
                                  mode: LaunchMode.externalApplication,
                                );
                              },
                              icon: const Icon(Icons.open_in_browser),
                              label: const Text('ブラウザで認証コードを取得'),
                            ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: controller,
                      decoration: const InputDecoration(
                        labelText: '認証コード',
                        border: OutlineInputBorder(),
                      ),
                      autofocus: true,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('キャンセル'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, controller.text.trim()),
                  child: const Text('ログイン'),
                ),
              ],
            );
          },
        );
      },
    );

    _logLoginStep(
      'fallback.mastodon.codeInput',
      data: {'hasCode': code != null && code.isNotEmpty},
    );
    if (code == null || code.isEmpty) return false;

    try {
      // Accept either a bare code or a full callback URL.
      //
      // 旧実装は「capsicum:// 以外は OOB と決め打ち」にしていたが、Linux で
      // `_redirectUri` が `http://localhost:7099/oauth/callback` (#507) に
      // なった結果、ユーザーがブラウザのアドレスバーから localhost callback
      // URL をそのまま貼ると OOB 強制で `invalid_grant` を踏む (#528)。
      // 「元の redirect_uri (custom scheme or localhost) と一致するか」で
      // 判定する形に変更。それ以外 (裸コード含む) は OOB 経由扱い。
      final String extractedCode;
      final bool codeFromOriginalRedirect;
      if (code.contains('code=')) {
        final uri = Uri.parse(code);
        extractedCode = uri.queryParameters['code'] ?? code;
        final isCustomScheme = uri.scheme == 'capsicum';
        final isLocalhostCallback =
            _useLocalhostCallback && uri.toString().startsWith(_redirectUri);
        codeFromOriginalRedirect = isCustomScheme || isLocalhostCallback;
      } else {
        extractedCode = code;
        // 裸コードは OOB ボタン経由とみなす (ブラウザに表示された 6 桁等)。
        codeFromOriginalRedirect = false;
      }

      // 元の redirect_uri 由来のコードなら同じ redirect_uri で交換 (Mastodon
      // の厳格 match 要件)。OOB 経由なら oobRedirect で交換。
      final exchangeExtra = Map<String, String>.from(extra);
      exchangeExtra['redirect_uri'] = codeFromOriginalRedirect
          ? _redirectUri
          : oobRedirect;
      exchangeExtra['client_id'] = clientId;
      exchangeExtra['client_secret'] = clientSecret;
      final callbackUri = Uri(queryParameters: {'code': extractedCode});
      final result = await loginSupport.completeLogin(
        callbackUri,
        exchangeExtra,
      );

      if (result is LoginSuccess) {
        final adapter = loginSupport as DecentralizedBackendAdapter;
        await _finishLogin(adapter, result);
        return true;
      } else if (result is LoginFailure) {
        debugPrint('Manual code login failed: ${result.error}');
        if (mounted) {
          setState(() => _error = '認証コードが正しくありません');
        }
      }
    } catch (e) {
      // DioException の場合 requestOptions.uri に client_secret が載る
      // Mastodon サーバ実装があるため、そのまま debugPrint すると AppImage
      // の AppRun ログ (~/.local/share/capsicum/logs/) に平文で残る (#499)。
      // util/exception_scrub.dart で URL を含まない安全な表現に詰め替える。
      debugLogException('Manual code fallback error', e);
      if (mounted) {
        setState(() => _error = '認証コードが正しくありません');
      }
    }
    return false;
  }

  Future<void> _finishLogin(
    DecentralizedBackendAdapter adapter,
    LoginSuccess result,
  ) async {
    _loginCompleted = true;
    final account = Account(
      key: AccountKey(
        type: widget.backendType,
        host: widget.host,
        username: result.user.username,
      ),
      adapter: adapter,
      user: result.user,
      userSecret: result.userSecret,
      clientSecret: result.clientSecret,
      softwareVersion: widget.softwareVersion,
    );

    // Persist client credentials at the host level so they survive
    // account deletion (avoids POST /api/v1/apps on re-login).
    //
    // ここから `addAccount` までは **widget の生死に依存させない** (#930)。
    // 認可は既に成功しているので、画面が消えていても保存は完走させる。
    // `ref` を使わず initState で掴んだ参照を使うのはそのため。
    if (result.clientSecret != null) {
      await _accountStorage.saveHostClientCredentials(
        widget.host,
        result.clientSecret!.clientId,
        result.clientSecret!.clientSecret,
        _redirectUri,
      );
    }

    await _accountManager.addAccount(account);
    // 以降は UI 操作なので mounted でガードする。
    if (!mounted) return;

    // ログイン直後はホームタイムラインを表示する。
    // 前回のタブ復元が走ると、存在しないリスト/ハッシュタグを参照してエラーになりうる。
    ref
        .read(lastTabProvider(account.key.toStorageKey()).notifier)
        .save('timeline:home');

    context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.host)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Server thumbnail
          // 横長ビューポート (macOS / タブレット landscape) で box が
          // 極端に横長になり上下がクリップされていたため、maxWidth 480 で
          // 頭打ちにして中央寄せする (#479)。
          // 候補にバナー(横長)だけでなく iconUrl(正方形ロゴ/favicon)も
          // 含む。バナーは cover で枠を埋め、アイコンは contain で天地を切らない
          // ように、選んだ画像種別に応じて fit を切り替える (#658)。
          if (_serverThumbnail != null)
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    _serverThumbnail!,
                    height: 160,
                    width: double.infinity,
                    fit: _serverThumbnailFit,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          // Server name + type
          Center(
            child: Text(
              _serverName ?? widget.host,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          Center(
            child: Text(
              widget.backendType.displayName,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          // Server description
          if (_serverDescription != null && _serverDescription!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _serverDescription!,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 24),
          if (_error != null) ...[
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
          ],
          Center(
            child: _isLoggingIn
                ? const CircularProgressIndicator()
                : FilledButton.icon(
                    onPressed: _login,
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text('ブラウザでログイン'),
                  ),
          ),
        ],
      ),
    );
  }
}

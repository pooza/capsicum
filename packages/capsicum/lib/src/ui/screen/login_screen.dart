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
import '../../url_helper.dart';
import '../../model/account.dart';
import '../../model/account_key.dart';
import '../../platform/platform_info.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../util/exception_scrub.dart';
import '../../util/login_error.dart';
import '../widget/content_parser.dart';

/// OAuth コールバック受信後にシステムブラウザへ表示する完了ページ (#654)。
const _oauthCallbackHtml =
    '<!doctype html><html lang="ja"><head><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width, initial-scale=1">'
    '<title>capsicum</title></head>'
    '<body style="font-family:-apple-system,sans-serif;text-align:center;'
    'padding:48px"><h2>ログイン処理が完了しました</h2>'
    '<p>このタブを閉じて capsicum に戻ってください。</p></body></html>';

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
  bool get _useLocalhostCallback => isDesktop;

  /// OAuth redirect URI。`_useLocalhostCallback` のときだけ
  /// `localhostOAuthCallbackUrl` (http://localhost:7099/oauth/callback)、
  /// それ以外は `capsicum://oauth` カスタムスキーム。
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

  // Server info
  String? _serverName;
  String? _serverDescription;
  String? _serverThumbnail;

  bool get _isMastodon => widget.backendType == BackendType.mastodon;

  @override
  void initState() {
    super.initState();
    _fetchServerInfo();
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
              // thumbnail が無ければ PWA アイコン (icon[] の 192px / 最大) で
              // 埋める。/api/v2/instance にマスコットは無い (#658)。
              _serverThumbnail = _pickImageUrl([
                thumbnail?['url'] as String?,
                _mastodonIcon192(data['icon']),
              ]);
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
              _serverThumbnail = _pickImageUrl([
                data['backgroundImageUrl'] as String?,
                data['bannerUrl'] as String?,
                data['app192IconUrl'] as String?,
                data['iconUrl'] as String?,
              ]);
            });
          }
        }
      }
    } catch (_) {
      // Server info is optional; ignore errors.
    }
  }

  String _stripHtml(String html) => stripHtml(html).trim();

  /// 候補 URL を先頭から走査し、最初の非空 URL を絶対化して返す (#658)。
  String? _pickImageUrl(List<String?> candidates) {
    for (final raw in candidates) {
      final normalized = _absoluteUrl(raw);
      if (normalized != null) return normalized;
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
      final width = int.tryParse((entry['size'] as String?)?.split('x').first ?? '') ?? 0;
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
          if (data != null) ...data,
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
  Future<String> _authenticateViaLocalhostServer(Uri authorizationUrl) async {
    // 127.0.0.1 で listen する。redirect_uri は `localhost` だが、macOS の
    // getaddrinfo は ::1 と 127.0.0.1 の両方を返し、ブラウザは Happy Eyeballs
    // で IPv4 にフォールバックするため loopbackIPv4 で受けられる。
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      AppConstants.localhostOAuthPort,
    );
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
        final uri = request.uri;
        // コールバックパスへの非空クエリ付きリクエストを認可リダイレクトとみなす。
        // favicon 等パスの異なるノイズ要求は 404 で受け流す。
        final isCallback =
            uri.path == callbackPath && uri.queryParameters.isNotEmpty;
        request.response
          ..statusCode = isCallback ? HttpStatus.ok : HttpStatus.notFound
          ..headers.contentType = ContentType.html
          ..write(isCallback ? _oauthCallbackHtml : '<!doctype html>');
        await request.response.close();
        if (isCallback && !completer.isCompleted) {
          completer.complete(uri);
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
    }
  }

  Future<void> _login({bool isRetry = false}) async {
    if (_loginCompleted) return;
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
        if (existing != null) {
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

        // Open browser and wait for callback redirect.
        assert(() {
          debugPrint('capsicum: OAuth URL: ${startResult.authorizationUrl}');
          return true;
        }());
        _logLoginStep('authenticate.begin');
        reachedAuthenticate = true;
        // localhost callback 経路では port 7099 が別プロセスで bind 済みだと
        // flutter_web_auth_2 server impl が internally EADDRINUSE を握って
        // authorization code を受け取れず、UX が「ログインに失敗しました」と
        // 出るだけでポート競合と判別できなくなる (#503)。authenticate 呼び出し
        // 直前に短時間 ServerSocket.bind を試して占有を専用エラーに昇格させる。
        if (_useLocalhostCallback) {
          final portError = await _checkOAuthPortAvailability();
          if (portError != null) {
            if (mounted) setState(() => _error = portError);
            return;
          }
        }
        final String resultUrl;
        if (Platform.isMacOS) {
          // #654: macOS は flutter_web_auth_2 に localhost callback の server
          // impl が無く、ASWebAuthenticationSession は ephemeral でパスワード
          // マネージャ拡張も効かない。Linux / Windows の server impl 相当を
          // 自前化し、システムブラウザ + 自前 localhost HTTP サーバで code を
          // 受ける（OOB の手動コード入力を廃止）。
          resultUrl = await _authenticateViaLocalhostServer(
            startResult.authorizationUrl,
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
        if (callbackUri.queryParameters.containsKey('error') &&
            !callbackUri.queryParameters.containsKey('code')) {
          final oauthError = callbackUri.queryParameters['error'];
          _logLoginStep(
            'authenticate.error_redirect',
            data: {'error': oauthError, 'usedCachedCreds': usedCachedCreds},
          );
          if (usedCachedCreds && _isMastodon && !isRetry) {
            _logLoginStep('login.error_retry.begin');
            try {
              final storage = ref.read(accountStorageProvider);
              await storage.deleteHostClientCredentials(widget.host);
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
          Sentry.captureException(
            scrubException(completeResult.error),
            stackTrace: completeResult.stackTrace,
          );
          if (mounted) setState(() => _error = 'ログインに失敗しました');
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
          final storage = ref.read(accountStorageProvider);
          await storage.deleteHostClientCredentials(widget.host);
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
        debugPrint('Login error (${failure.kind.name}): $e');
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
        debugPrint('capsicum: OOB app re-registration failed: $e');
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
                                final launched = await launchUrlSafely(
                                  oobUrl,
                                  mode: LaunchMode.externalApplication,
                                );
                                if (!launched && dialogContext.mounted) {
                                  ScaffoldMessenger.of(
                                    dialogContext,
                                  ).showSnackBar(
                                    const SnackBar(
                                      content: Text('ブラウザを開けませんでした'),
                                    ),
                                  );
                                }
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
      debugPrint('Manual code fallback error: ${scrubException(e)}');
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
    if (result.clientSecret != null) {
      final storage = ref.read(accountStorageProvider);
      await storage.saveHostClientCredentials(
        widget.host,
        result.clientSecret!.clientId,
        result.clientSecret!.clientSecret,
        _redirectUri,
      );
    }

    await ref.read(accountManagerProvider.notifier).addAccount(account);
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
          // 極端に横長になり BoxFit.cover で上下がクリップされていたため、
          // maxWidth 480 で頭打ちにして中央寄せする (#479)。
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
                    fit: BoxFit.cover,
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
          if (requiresManualCodeFallbackCard) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'ブラウザから戻れないとき',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Android ではブラウザから自動でアプリに戻れないことがあります。'
                      'その場合は端末のスワイプや戻るボタンでアプリに戻ってください。'
                      '多くの場合、認証は自動で完了します。\n\n'
                      '認証画面以外（タイムラインなど）に遷移してしまった場合は、'
                      '一度スワイプで戻ると認証コード入力ダイアログが出るので、'
                      'そこからブラウザを開き直して認証コードを取得・貼り付けて'
                      'ログインできます。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

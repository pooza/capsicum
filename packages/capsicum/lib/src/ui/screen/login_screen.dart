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
import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../service/exception_scrub.dart';
import '../widget/content_parser.dart';

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
  /// どうか。`desktop_webview_window` の GLX 系 native crash (#489 / #496)
  /// を回避するため、Linux のみ true。Windows 対応再開時に true 化する
  /// 可能性があるため、地域名でなく機能ベース命名を採用 (#507)。
  bool get _useLocalhostCallback => Platform.isLinux;

  /// OAuth redirect URI。`_useLocalhostCallback` のときだけ
  /// `linuxOAuthCallbackUrl` (http://localhost:7099/oauth/callback)、
  /// それ以外は `capsicum://oauth` カスタムスキーム。
  String get _redirectUri => _useLocalhostCallback
      ? AppConstants.linuxOAuthCallbackUrl
      : AppConstants.customSchemeOAuthCallbackUrl;

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
              _serverThumbnail = thumbnail?['url'] as String?;
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
              _serverThumbnail = data['bannerUrl'] as String?;
            });
          }
        }
      }
    } catch (_) {
      // Server info is optional; ignore errors.
    }
  }

  String _stripHtml(String html) => stripHtml(html).trim();

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

  /// localhost callback 用のポート ([AppConstants.linuxOAuthPort]) が
  /// 別プロセスに占有されているかを試し、占有時は専用エラー文を返す。
  /// 空いていれば null を返す。TOCTOU はあるが、flutter_web_auth_2 側で
  /// EADDRINUSE を握って authorization code を取り逃がす UX 劣化を
  /// 識別可能な error に置き換えるための実用的な防御 (#503)。
  Future<String?> _checkOAuthPortAvailability() async {
    try {
      final socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        AppConstants.linuxOAuthPort,
      );
      await socket.close();
      return null;
    } on SocketException catch (e) {
      _logLoginStep(
        'oauth_port.occupied',
        data: {
          'port': AppConstants.linuxOAuthPort,
          'error': e.osError?.message ?? e.message,
        },
      );
      return 'OAuth コールバック用ポート ${AppConstants.linuxOAuthPort} が'
          '他プロセスに占有されています。占有中のアプリを閉じてから再試行してください。';
    }
  }

  Future<void> _login() async {
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

    _logLoginStep('login.start');

    try {
      adapter = await widget.backendType.createAdapter(widget.host);
      final loginSupport = adapter as LoginSupport;

      // Reuse cached client credentials to avoid calling POST /api/v1/apps
      // (rate-limit prone). Check: 1) existing accounts, 2) host-level storage.
      if (adapter is MastodonAdapter) {
        final accounts = ref.read(accountManagerProvider).accounts;
        final existing = accounts
            .where((a) => a.key.host == widget.host && a.clientSecret != null)
            .firstOrNull;
        if (existing != null) {
          adapter.setCachedClientCredentials(existing.clientSecret);
        } else {
          final storage = ref.read(accountStorageProvider);
          final hostCreds = await storage.getHostClientCredentials(widget.host);
          if (hostCreds != null) {
            adapter.setCachedClientCredentials(hostCreds);
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
        // localhost callback では `desktop_webview_window` の GLX 系 native
        // crash (#489 / #496) を回避するため useWebview: false で
        // システムブラウザ + 自前 HTTP サーバ (flutter_web_auth_2 server impl)
        // で受ける。callbackUrlScheme は server impl では完全な
        // http://localhost:{port}/{path} URL を期待する仕様 (flutter_web_auth_2
        // 4.1.0 の server.dart 参照)。
        // 現状 Linux のみ true (Windows 対応再開時に true 化検討)。
        final resultUrl = await FlutterWebAuth2.authenticate(
          url: startResult.authorizationUrl.toString(),
          callbackUrlScheme: _useLocalhostCallback
              ? AppConstants.linuxOAuthCallbackUrl
              : AppConstants.callbackUrlScheme,
          options: _useLocalhostCallback
              ? const FlutterWebAuth2Options(useWebview: false)
              : const FlutterWebAuth2Options(preferEphemeral: true),
        );
        authenticateReturned = true;
        _logLoginStep('authenticate.end');

        final callbackUri = Uri.parse(resultUrl);
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
            completeResult.error,
            stackTrace: completeResult.stackTrace,
          );
          if (mounted) setState(() => _error = 'ログインに失敗しました');
        }
      } else if (startResult is LoginFailure) {
        debugPrint('Login start failed: ${startResult.error}');
        Sentry.captureException(
          startResult.error,
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
        },
      );

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
            e,
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
        debugPrint('Login error: $e');
        Sentry.captureException(e, stackTrace: st);
        if (mounted) setState(() => _error = '通信に失敗しました');
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
        await storage.saveHostClientCredentials(
          widget.host,
          clientId,
          clientSecret,
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
      // service/exception_scrub.dart で URL を含まない安全な表現に詰め替える。
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
          if (_serverThumbnail != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                _serverThumbnail!,
                height: 160,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
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
          if (Platform.isAndroid) ...[
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

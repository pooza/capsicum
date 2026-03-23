import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:go_router/go_router.dart';

import '../../constants.dart';
import '../../model/account.dart';
import '../../model/account_key.dart';
import '../../provider/account_manager_provider.dart';

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
  static final _redirectUri = '${AppConstants.callbackUrlScheme}://oauth';

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

  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</p>\s*<p>'), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .trim();
  }

  Future<void> _login() async {
    if (_loginCompleted) return;
    setState(() {
      _isLoggingIn = true;
      _error = null;
    });

    try {
      final adapter = await widget.backendType.createAdapter(widget.host);
      final loginSupport = adapter as LoginSupport;

      // Reuse cached client credentials from an existing account on the same
      // host to avoid calling POST /api/v1/apps (rate-limit prone).
      if (adapter is MastodonAdapter) {
        final accounts = ref.read(accountManagerProvider).accounts;
        final existing = accounts
            .where((a) => a.key.host == widget.host && a.clientSecret != null)
            .firstOrNull;
        if (existing != null) {
          adapter.setCachedClientCredentials(existing.clientSecret);
        }
      }

      final application = ApplicationInfo(
        name: AppConstants.appName,
        redirectUri: Uri.parse(_redirectUri),
        scopes: const ['read', 'write', 'follow', 'push'],
        website: AppConstants.websiteUrl,
      );

      final startResult = await loginSupport.startLogin(application);

      if (startResult is LoginNeedsOAuth) {
        // Open browser and wait for callback redirect.
        final resultUrl = await FlutterWebAuth2.authenticate(
          url: startResult.authorizationUrl.toString(),
          callbackUrlScheme: AppConstants.callbackUrlScheme,
          options: const FlutterWebAuth2Options(preferEphemeral: false),
        );

        final callbackUri = Uri.parse(resultUrl);
        final completeResult = await loginSupport.completeLogin(
          callbackUri,
          startResult.extra,
        );

        if (completeResult is LoginSuccess) {
          _loginCompleted = true;
          final account = Account(
            key: AccountKey(
              type: widget.backendType,
              host: widget.host,
              username: completeResult.user.username,
            ),
            adapter: adapter,
            user: completeResult.user,
            userSecret: completeResult.userSecret,
            clientSecret: completeResult.clientSecret,
            softwareVersion: widget.softwareVersion,
          );

          await ref.read(accountManagerProvider.notifier).addAccount(account);
          if (mounted) context.go('/home');
        } else if (completeResult is LoginFailure) {
          debugPrint('Login failed: ${completeResult.error}');
          setState(() => _error = 'ログインに失敗しました');
        }
      } else if (startResult is LoginFailure) {
        debugPrint('Login start failed: ${startResult.error}');
        final errorMsg = startResult.error;
        setState(
          () => _error = errorMsg is String ? errorMsg : 'ログインの開始に失敗しました',
        );
      }
    } catch (e) {
      // User cancelled the browser — not an error.
      if (e.toString().contains('CANCELED') ||
          e.toString().contains('cancelled')) {
        // Do nothing.
      } else {
        debugPrint('Login error: $e');
        setState(() => _error = '通信に失敗しました');
      }
    } finally {
      if (mounted) setState(() => _isLoggingIn = false);
    }
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
        ],
      ),
    );
  }
}

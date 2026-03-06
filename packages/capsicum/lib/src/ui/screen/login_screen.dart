import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../model/account.dart';
import '../../model/account_key.dart';
import '../../provider/account_manager_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  final String host;
  final BackendType backendType;

  const LoginScreen({super.key, required this.host, required this.backendType});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _codeController = TextEditingController();
  bool _isLoggingIn = false;
  bool _awaitingInput = false;
  String? _error;

  // Server info
  String? _serverName;
  String? _serverDescription;
  String? _serverThumbnail;

  bool get _isMastodon => widget.backendType == BackendType.mastodon;

  String get _redirectUri =>
      _isMastodon ? 'urn:ietf:wg:oauth:2.0:oob' : 'capsicum://oauth';

  // Store login state between phases
  dynamic _adapter;
  LoginNeedsOAuth? _oauthState;

  @override
  void initState() {
    super.initState();
    _fetchServerInfo();
  }

  @override
  void dispose() {
    _codeController.dispose();
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

  Future<void> _openBrowser() async {
    setState(() {
      _isLoggingIn = true;
      _error = null;
    });

    try {
      final adapter = await widget.backendType.createAdapter(widget.host);
      final loginSupport = adapter as LoginSupport;

      final application = ApplicationInfo(
        name: 'capsicum',
        redirectUri: Uri.parse(_redirectUri),
        scopes: const ['read', 'write', 'follow', 'push'],
      );

      final startResult = await loginSupport.startLogin(application);

      if (startResult is LoginNeedsOAuth) {
        _adapter = adapter;
        _oauthState = startResult;

        await launchUrl(
          startResult.authorizationUrl,
          mode: LaunchMode.externalApplication,
        );

        setState(() {
          _awaitingInput = true;
          _isLoggingIn = false;
        });
      } else if (startResult is LoginFailure) {
        setState(() => _error = 'ログインの開始に失敗しました: ${startResult.error}');
      }
    } catch (e) {
      setState(() => _error = 'エラー: $e');
    } finally {
      if (mounted && !_awaitingInput) {
        setState(() => _isLoggingIn = false);
      }
    }
  }

  Future<void> _completeAuth() async {
    if (_oauthState == null || _adapter == null) return;

    // Mastodon: require code input; Misskey: just check the session
    if (_isMastodon && _codeController.text.trim().isEmpty) return;

    setState(() {
      _isLoggingIn = true;
      _error = null;
    });

    try {
      final loginSupport = _adapter as LoginSupport;

      final callbackUri = _isMastodon
          ? Uri.parse('$_redirectUri?code=${_codeController.text.trim()}')
          : Uri.parse(_redirectUri);

      final completeResult = await loginSupport.completeLogin(
        callbackUri,
        _oauthState!.extra,
      );

      if (completeResult is LoginSuccess) {
        final account = Account(
          key: AccountKey(
            type: widget.backendType,
            host: widget.host,
            username: completeResult.user.username,
          ),
          adapter: _adapter as DecentralizedBackendAdapter,
          user: completeResult.user,
          userSecret: completeResult.userSecret,
          clientSecret: completeResult.clientSecret,
        );

        await ref.read(accountManagerProvider.notifier).addAccount(account);
        if (mounted) context.go('/home');
      } else if (completeResult is LoginFailure) {
        setState(() => _error = 'ログインに失敗しました: ${completeResult.error}');
      }
    } catch (e) {
      setState(() => _error = 'エラー: $e');
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
          if (!_awaitingInput) ...[
            Center(
              child: _isLoggingIn
                  ? const CircularProgressIndicator()
                  : FilledButton.icon(
                      onPressed: _openBrowser,
                      icon: const Icon(Icons.open_in_browser),
                      label: const Text('ブラウザでログイン'),
                    ),
            ),
          ] else ...[
            if (_isMastodon) ...[
              const Text(
                'ブラウザで認証後、表示されたコードを入力してください',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _codeController,
                decoration: const InputDecoration(
                  labelText: '認証コード',
                  hintText: 'コードを貼り付け',
                  prefixIcon: Icon(Icons.key),
                ),
                autocorrect: false,
                onSubmitted: (_) => _completeAuth(),
              ),
            ] else ...[
              const Text(
                'ブラウザで認証を完了したら、下のボタンを押してください',
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: _isLoggingIn
                  ? const Center(child: CircularProgressIndicator())
                  : FilledButton(
                      onPressed: _completeAuth,
                      child: Text(_isMastodon ? 'ログイン' : '認証を完了'),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

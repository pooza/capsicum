import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
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

  const LoginScreen({
    super.key,
    required this.host,
    required this.backendType,
  });

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _codeController = TextEditingController();
  bool _isLoggingIn = false;
  bool _awaitingInput = false;
  String? _error;

  bool get _isMastodon => widget.backendType == BackendType.mastodon;

  String get _redirectUri => _isMastodon
      ? 'urn:ietf:wg:oauth:2.0:oob'
      : 'capsicum://oauth';

  // Store login state between phases
  dynamic _adapter;
  LoginNeedsOAuth? _oauthState;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
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
        setState(
          () => _error = 'ログインの開始に失敗しました: ${startResult.error}',
        );
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
        setState(
          () => _error = 'ログインに失敗しました: ${completeResult.error}',
        );
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
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${widget.backendType.name} サーバーにログイン',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 24),
              if (_error != null) ...[
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (!_awaitingInput) ...[
                _isLoggingIn
                    ? const CircularProgressIndicator()
                    : FilledButton.icon(
                      onPressed: _openBrowser,
                      icon: const Icon(Icons.open_in_browser),
                      label: const Text('ブラウザでログイン'),
                    ),
              ] else ...[
                if (_isMastodon) ...[
                  const Text('ブラウザで認証後、表示されたコードを入力してください'),
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
                  const Text('ブラウザで認証を完了したら、下のボタンを押してください'),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child:
                      _isLoggingIn
                          ? const Center(child: CircularProgressIndicator())
                          : FilledButton(
                            onPressed: _completeAuth,
                            child: Text(_isMastodon ? 'ログイン' : '認証を完了'),
                          ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

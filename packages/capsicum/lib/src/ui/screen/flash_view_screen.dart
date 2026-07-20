import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../util/oauth_scope_error.dart';
import '../flash/flash_runtime.dart';
import '../flash/flash_view.dart';
import '../util/flash_error.dart';
import '../widget/user_avatar.dart';

/// Misskey Flash（UI 表記は **Play**）の詳細画面 (#830)。
///
/// #73 では一覧から外部ブラウザに投げていたが、AiScript をネイティブ実行して
/// `Ui:` 由来の描画ツリーをそのまま widget として表示する。
///
/// ドロワーからの導線は「クイックチューザ（ボトムシート）で 1 本選び、
/// 滞在する行き先はこの独立画面」という #805 の様式に従う。
class FlashViewScreen extends ConsumerStatefulWidget {
  const FlashViewScreen({super.key, this.initialFlash, this.flashId})
    : assert(
        initialFlash != null || flashId != null,
        'either initialFlash or flashId must be provided',
      );

  /// 一覧から遷移する経路（取得済みを渡す）。
  final Flash? initialFlash;

  /// id だけ分かっている経路。
  final String? flashId;

  @override
  ConsumerState<FlashViewScreen> createState() => _FlashViewScreenState();
}

class _FlashViewScreenState extends ConsumerState<FlashViewScreen> {
  late Future<Flash> _future;
  bool _resolving = true;

  @override
  void initState() {
    super.initState();
    _future = _trackResolve();
  }

  Future<Flash> _trackResolve() async {
    _resolving = true;
    try {
      return await _resolve();
    } finally {
      _resolving = false;
    }
  }

  Future<Flash> _resolve() async {
    try {
      // 一覧 (flash/featured) のレスポンスにも script は含まれるが、経路に
      // よっては欠けうるので、その場合だけ show で取り直す。
      final initial = widget.initialFlash;
      if (initial != null && initial.script.isNotEmpty) return initial;

      final raw = ref.read(currentAdapterProvider);
      if (raw is! FlashSupport) {
        throw StateError('current adapter does not support Flash');
      }
      return await (raw as FlashSupport).getFlashById(
        initial?.id ?? widget.flashId!,
      );
    } catch (e, st) {
      reportFlashOpFailure(
        'view',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Play'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: FutureBuilder<Flash>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            // snapshot.error はそのまま出さない。Misskey の URL には
            // ?i=<accessToken> が載るため (#460 同型)。
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Play の読み込みに失敗しました',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _resolving
                          ? null
                          : () => setState(() => _future = _trackResolve()),
                      child: const Text('再試行'),
                    ),
                  ],
                ),
              ),
            );
          }
          return _FlashBody(flash: snapshot.data!);
        },
      ),
    );
  }
}

class _FlashBody extends ConsumerStatefulWidget {
  const _FlashBody({required this.flash});

  final Flash flash;

  @override
  ConsumerState<_FlashBody> createState() => _FlashBodyState();
}

class _FlashBodyState extends ConsumerState<_FlashBody> {
  FlashRuntime? _runtime;
  FlashRuntimeError? _error;
  bool _running = false;

  late bool _isLiked = widget.flash.isLiked;
  late int _likedCount = widget.flash.likedCount;
  bool _toggling = false;

  String? get _host {
    final adapter = ref.read(currentAdapterProvider);
    return adapter is DecentralizedBackendAdapter ? adapter.host : null;
  }

  /// 初回実行を 1 度だけ発火させるためのフラグ。[_running] は非同期に立つので
  /// build の再入判定には使えない。
  bool _started = false;

  @override
  void dispose() {
    _runtime?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final host = _host;
    if (host == null || _running) return;

    final account = ref.read(currentAccountProvider);
    final emojis = ref.read(customEmojisProvider).valueOrNull ?? const [];
    final runtime = FlashRuntime(
      flashId: widget.flash.id,
      host: host,
      customEmojis: [
        for (final e in emojis) (name: e.shortcode, category: e.category),
      ],
      userId: account?.user.id,
      userName: account?.user.displayName ?? account?.user.username,
      userUsername: account?.user.username,
    );
    runtime.onCallbackError = (error, stackTrace) =>
        reportFlashOpFailure('callback', error, stackTrace, account: account);

    setState(() {
      _running = true;
      _error = null;
      _runtime?.dispose();
      _runtime = runtime;
    });

    try {
      await runtime.run(widget.flash.script);
    } on FlashRuntimeError catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _toggleLike() async {
    if (_toggling) return;
    final raw = ref.read(currentAdapterProvider);
    if (raw is! FlashSupport) return;
    final flashes = raw as FlashSupport;

    final wasLiked = _isLiked;
    setState(() {
      _toggling = true;
      _isLiked = !wasLiked;
      _likedCount += wasLiked ? -1 : 1;
    });
    try {
      if (wasLiked) {
        await flashes.unlikeFlash(widget.flash.id);
      } else {
        await flashes.likeFlash(widget.flash.id);
      }
    } catch (e, st) {
      reportFlashOpFailure(
        wasLiked ? 'unlike' : 'like',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (!mounted) return;
      setState(() {
        _isLiked = wasLiked;
        _likedCount += wasLiked ? 1 : -1;
      });
      // 旧トークン (write:flash-likes 未付与) は 403 PERMISSION_DENIED。
      // 汎用文言ではなく再ログインが要る旨を伝える (#615 と同型)。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isOAuthScopeError(e) ? '権限が不足しています。再ログインしてください' : 'いいねの更新に失敗しました',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final flash = widget.flash;
    final theme = Theme.of(context);
    final runtime = _runtime;

    // カスタム絵文字のロード完了を待ってから実行する。実在の Play には
    // CUSTOM_EMOJIS を必須で使うものがあり、空で走らせると結果が変わる。
    // ここを didChangeDependencies + read で書くと、初回 build 時点では
    // AsyncLoading なので発火せず、解決後も再評価されないため **スクリプトが
    // 永久に実行されない**。watch して解決後の rebuild を拾うこと。
    final emojis = ref.watch(customEmojisProvider);
    if (!_started && !emojis.isLoading) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _start();
      });
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                flash.title,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (flash.summary != null && flash.summary!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  flash.summary!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  UserAvatar(user: flash.author, size: 24),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      flash.author.displayName ?? flash.author.username,
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _toggling ? null : _toggleLike,
                    icon: Icon(
                      _isLiked ? Icons.favorite : Icons.favorite_border,
                      size: 18,
                      color: _isLiked ? theme.colorScheme.primary : null,
                    ),
                    label: Text('$_likedCount'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(16),
          child: switch ((_running, _error, runtime)) {
            (true, _, _) => const Center(child: CircularProgressIndicator()),
            (_, final FlashRuntimeError error, _) => _RunError(
              error: error,
              host: _host,
              flashId: flash.id,
              onRetry: _start,
            ),
            (_, _, final FlashRuntime r) => FlashView(runtime: r),
            _ => const SizedBox.shrink(),
          },
        ),
        if (_error == null && !_running)
          Center(
            child: TextButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('もう一度実行'),
            ),
          ),
      ],
    );
  }
}

class _RunError extends StatelessWidget {
  const _RunError({
    required this.error,
    required this.host,
    required this.flashId,
    required this.onRetry,
  });

  final FlashRuntimeError error;
  final String? host;
  final String flashId;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(Icons.error_outline, color: theme.colorScheme.error),
        const SizedBox(height: 8),
        Text(error.summary, textAlign: TextAlign.center),
        if (error.detail.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            error.detail,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          alignment: WrapAlignment.center,
          children: [
            TextButton(onPressed: onRetry, child: const Text('再試行')),
            // capsicum が実行できない Play でも、本家の web UI なら動く。
            // 行き止まりにしない。
            if (host != null)
              TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('https://$host/play/$flashId'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('ブラウザで開く'),
              ),
          ],
        ),
      ],
    );
  }
}

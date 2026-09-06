import 'package:capsicum_core/capsicum_core.dart';
// Flutter material の `Page` (Navigator) と capsicum_core の `Page` が
// 衝突するため Flutter 側を hide する。本画面では Misskey ページのみ扱う。
import 'package:flutter/material.dart' hide Page;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../util/oauth_scope_error.dart';
import '../util/pages_error.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/page_block_renderer.dart';
import '../widget/user_avatar.dart';

/// Misskey ページ詳細画面 (#186)。
///
/// 起動経路は 2 通り:
/// - プロフィールタブ「ページ」一覧から (Page を直接渡す)
/// - 外部リンク `/@user/pages/<name>` からの遷移 (username + name から fetch)
class PageViewScreen extends ConsumerStatefulWidget {
  /// 既に取得済みの Page を直接渡す経路。
  final Page? initialPage;

  /// fetch 経路 (外部リンク用)。`initialPage == null` のときに使う。
  final String? pageId;
  final String? username;
  final String? name;

  const PageViewScreen({
    super.key,
    this.initialPage,
    this.pageId,
    this.username,
    this.name,
  }) : assert(
         initialPage != null ||
             pageId != null ||
             (username != null && name != null),
         'either initialPage or pageId or (username, name) must be provided',
       );

  @override
  ConsumerState<PageViewScreen> createState() => _PageViewScreenState();
}

class _PageViewScreenState extends ConsumerState<PageViewScreen> {
  late Future<Page> _future;
  // 「再試行」連打で _resolve() が並走し Sentry に重複イベントが乗らないよう
  // 直近の Future が完走するまで次の _resolve() を発火しない (2 回目レビュー追従)。
  bool _resolving = true;

  @override
  void initState() {
    super.initState();
    _future = _trackResolve();
  }

  Future<Page> _trackResolve() async {
    _resolving = true;
    try {
      return await _resolve();
    } finally {
      _resolving = false;
    }
  }

  Future<Page> _resolve() async {
    try {
      if (widget.initialPage != null) return widget.initialPage!;
      final raw = ref.read(currentAdapterProvider);
      if (raw is! PagesSupport) {
        throw StateError('current adapter does not support Pages');
      }
      final pages = raw as PagesSupport;
      if (widget.pageId != null) {
        return await pages.getPageById(widget.pageId!);
      }
      return await pages.getPageByName(
        username: widget.username!,
        name: widget.name!,
      );
    } catch (e, st) {
      // 失敗時の例外 (典型は DioException) は requestOptions.uri に
      // Misskey の `?i=<accessToken>` が載るため、scrubException で詰め替えて
      // から rethrow する。UI 側 (FutureBuilder の error branch) では
      // snapshot.error を表示せず汎用文言にとどめ、画面スクショ経由でも
      // token が漏れない経路に揃える (#460 と同型を回避)。
      reportPagesOpFailure('view', e, st, account: ref.accountForReport);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ページ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: BottomSafeArea(
        child: FutureBuilder<Page>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'ページの読み込みに失敗しました',
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
            return _PageBody(page: snapshot.data!);
          },
        ),
      ),
    );
  }
}

class _PageBody extends ConsumerStatefulWidget {
  final Page page;

  const _PageBody({required this.page});

  @override
  ConsumerState<_PageBody> createState() => _PageBodyState();
}

class _PageBodyState extends ConsumerState<_PageBody> {
  // like 状態はサーバー往復を待たず楽観更新する。失敗時は元に戻す。
  late bool _isLiked = widget.page.isLiked;
  late int _likedCount = widget.page.likedCount;
  // 連打で like/unlike が交錯しないよう、往復中は再操作を弾く。
  bool _toggling = false;

  Future<void> _toggleLike() async {
    if (_toggling) return;
    final raw = ref.read(currentAdapterProvider);
    if (raw is! PagesSupport) return;
    final pages = raw as PagesSupport;

    final wasLiked = _isLiked;
    setState(() {
      _toggling = true;
      _isLiked = !wasLiked;
      _likedCount += wasLiked ? -1 : 1;
    });
    try {
      if (wasLiked) {
        await pages.unlikePage(widget.page.id);
      } else {
        await pages.likePage(widget.page.id);
      }
    } catch (e, st) {
      // token 漏洩を避けるため scrubException 経由で Sentry に送り、UI には
      // 汎用文言だけ出す (view 経路と同型 / #460)。
      reportPagesOpFailure(
        wasLiked ? 'unlike' : 'like',
        e,
        st,
        account: ref.accountForReport,
      );
      if (!mounted) return;
      setState(() {
        _isLiked = wasLiked;
        _likedCount += wasLiked ? 1 : -1;
      });
      // 旧トークン (write:page-likes 未付与) は 403 PERMISSION_DENIED。汎用
      // 文言ではなく再ログインが要る旨を伝える (#615)。自分のページへの like は
      // Misskey 仕様 (yourPage) で弾かれるが、そちらは scope エラーではないので
      // 汎用文言のまま。
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
    final page = widget.page;
    final theme = Theme.of(context);
    final adapter = ref.watch(currentAdapterProvider);
    final host = adapter is DecentralizedBackendAdapter ? adapter.host : null;

    return ListView(
      children: [
        if (page.eyeCatchingImage != null)
          Image.network(
            page.eyeCatchingImage!.url,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                page.title,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (page.summary != null && page.summary!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  page.summary!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  UserAvatar(user: page.author, size: 28),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      page.author.displayName ?? page.author.username,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    _formatDate(page.updatedAt),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _toggling ? null : _toggleLike,
                  icon: Icon(
                    _isLiked ? Icons.favorite : Icons.favorite_border,
                    color: _isLiked ? theme.colorScheme.primary : null,
                  ),
                  label: Text('$_likedCount'),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        PageBlockRenderer(
          blocks: page.content,
          attachedFiles: page.attachedFiles,
          host: host,
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  String _formatDate(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/'
      '${d.day.toString().padLeft(2, '0')}';
}

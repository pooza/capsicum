import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/flash_provider.dart';
import '../../util/oauth_scope_error.dart';
import '../util/deck_navigation.dart';
import '../util/flash_error.dart';
import '../util/op_error.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/retry_error_view.dart';

/// Play を探す・自分の Play を削除する画面 (#1351)。
///
/// ⚠ 作成と編集は置かない（#1074）。⚠ 実行できるかの判定は開いた先
/// （[openFlash]）が持つので、検索結果に世代の合わない Play が混ざっていても
/// ここでは分けない。
class FlashBrowserScreen extends ConsumerStatefulWidget {
  const FlashBrowserScreen({super.key});

  @override
  ConsumerState<FlashBrowserScreen> createState() => _FlashBrowserScreenState();
}

class _FlashBrowserScreenState extends ConsumerState<FlashBrowserScreen>
    with SingleTickerProviderStateMixin {
  final _search = TextEditingController();
  late final TabController _tabs = TabController(
    length: FlashListKind.values.length,
    vsync: this,
  );
  String _query = '';

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Play'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: BottomSafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Play を検索',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: '検索をやめる',
                          onPressed: _clearSearch,
                        ),
                ),
                onSubmitted: (value) => setState(() => _query = value.trim()),
              ),
            ),
            if (_query.isNotEmpty)
              Expanded(
                child: _FlashList(
                  provider: flashSearchProvider(_query),
                  emptyMessage: '見つかりませんでした',
                  onRetry: () => ref.invalidate(flashSearchProvider(_query)),
                ),
              )
            else ...[
              TabBar(
                controller: _tabs,
                tabs: [
                  for (final kind in FlashListKind.values)
                    Tab(text: kind.label),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    for (final kind in FlashListKind.values)
                      _FlashList(
                        provider: flashListProvider(kind),
                        emptyMessage: kind.emptyMessage,
                        deletable: kind == FlashListKind.mine,
                        onRetry: () => ref.invalidate(flashListProvider(kind)),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 権限の足りない古いトークンの案内。`write:flash` は #1351 で足した。
const _scopeErrorMessage = '権限が不足しています。再ログインしてください';

class _FlashList extends ConsumerWidget {
  const _FlashList({
    required this.provider,
    required this.emptyMessage,
    required this.onRetry,
    this.deletable = false,
  });

  final ProviderListenable<AsyncValue<List<Flash>>> provider;
  final String emptyMessage;
  final VoidCallback onRetry;
  final bool deletable;

  Future<void> _delete(BuildContext context, WidgetRef ref, Flash flash) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! FlashSupport) return;
    final messenger = ScaffoldMessenger.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    final account = ref.read(currentAccountProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Play を削除'),
        content: Text('「${flash.title}」を削除しますか？\nこの操作は取り消せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await (adapter as FlashSupport).deleteFlash(flash.id);
    } catch (e, st) {
      if (isOAuthScopeError(e)) {
        messenger.showSnackBar(
          const SnackBar(content: Text(_scopeErrorMessage)),
        );
        return;
      }
      reportFlashOpFailure('delete', e, st, account: account);
      messenger.showSnackBar(
        SnackBar(content: Text('Play を削除できませんでした\n${summarizeOpError(e)}')),
      );
      return;
    }
    // ⚠ 通信の間に行が破棄されていても取り直せるよう、コンテナへ当てる。
    container.invalidate(flashListProvider);
    container.invalidate(flashSearchProvider);
    messenger.showSnackBar(const SnackBar(content: Text('Play を削除しました')));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flashes = ref.watch(provider);
    return flashes.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => RetryErrorView(
        message: isOAuthScopeError(e)
            ? _scopeErrorMessage
            : '読み込みに失敗しました\n${summarizeOpError(e)}',
        isRetrying: flashes.isLoading,
        onRetry: onRetry,
      ),
      data: (list) {
        if (list.isEmpty) return Center(child: Text(emptyMessage));
        return ListView.separated(
          itemCount: list.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final flash = list[index];
            final summary = flash.summary;
            return ListTile(
              leading: Icon(
                flash.visibility == 'private'
                    ? Icons.lock_outline
                    : Icons.play_circle_outline,
              ),
              title: Text(
                flash.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: summary == null || summary.isEmpty
                  ? null
                  : Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => openFlash(context, flash: flash),
              trailing: deletable
                  ? IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '削除',
                      onPressed: () => _delete(context, ref, flash),
                    )
                  : null,
            );
          },
        );
      },
    );
  }
}

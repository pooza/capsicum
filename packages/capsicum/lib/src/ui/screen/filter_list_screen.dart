import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../util/filter_labels.dart';
import '../widget/bottom_safe_area.dart';

/// フィルターの一覧 (#1047)。Mastodon の `api/v2/filters`。
///
/// ⚠ **入口の名前は SNS の本来の用語**（Mastodon は「フィルター」・2026-10-15 pooza
/// 判断）。Misskey のワードミュートは別の画面（#1290）で、ここは
/// [FilterSupport] を持つアダプターでだけ開く。設計は
/// `docs/filter-management-plan.md` 決定済み事項 5。
class FilterListScreen extends ConsumerStatefulWidget {
  const FilterListScreen({super.key});

  @override
  ConsumerState<FilterListScreen> createState() => _FilterListScreenState();
}

class _FilterListScreenState extends ConsumerState<FilterListScreen> {
  Future<List<ServerFilter>>? _filters;

  /// 一覧がどのアカウントのものか。⚠ 切り替えたら取り直す（前のアカウントの
  /// フィルターを、切替後のアカウントへ書き込ませない）。
  String? _loadedFor;

  /// 取得して、失敗を 1 回だけ報告する。⚠ build の中で報告すると再描画のたびに
  /// 積まれるので、future の側で済ませる。
  Future<List<ServerFilter>> _load(FilterSupport support) async {
    final account = ref.read(currentAccountProvider);
    try {
      return await support.getFilters();
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'filter.op',
        operation: 'list',
        error: e,
        stackTrace: st,
        account: account,
      );
      rethrow;
    }
  }

  void _reload(FilterSupport support) {
    setState(() => _filters = _load(support));
  }

  Future<void> _open(FilterSupport support, ServerFilter? filter) async {
    final changed = await context.push<bool>(
      '/settings/filters/edit',
      extra: filter,
    );
    if (changed == true && mounted) _reload(support);
  }

  @override
  Widget build(BuildContext context) {
    final adapter = ref.watch(currentAdapterProvider);
    final support = adapter is FilterSupport ? adapter as FilterSupport : null;
    final accountKey = ref.watch(currentAccountProvider)?.key.toStorageKey();
    if (support != null && _loadedFor != accountKey) {
      _loadedFor = accountKey;
      _filters = _load(support);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('フィルター'),
        actions: [
          if (support != null)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '新規作成',
              onPressed: () => _open(support, null),
            ),
        ],
      ),
      body: BottomSafeArea(
        child: support == null
            ? const Center(child: Text('このアカウントではフィルターを使えません'))
            : FutureBuilder<List<ServerFilter>>(
                future: _filters,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('読み込みに失敗しました'),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () => _reload(support),
                            child: const Text('再読み込み'),
                          ),
                        ],
                      ),
                    );
                  }
                  final filters = snapshot.data ?? const [];
                  return RefreshIndicator(
                    onRefresh: () async {
                      _reload(support);
                      await _filters;
                    },
                    child: filters.isEmpty
                        ? ListView(
                            children: const [
                              SizedBox(height: 120),
                              Center(child: Text('フィルターはありません')),
                              SizedBox(height: 8),
                              Center(
                                child: Text(
                                  '右上の＋ボタンから作成できます',
                                  style: TextStyle(color: Colors.grey),
                                ),
                              ),
                            ],
                          )
                        : ListView.separated(
                            itemCount: filters.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) => _FilterRow(
                              filter: filters[index],
                              onTap: () => _open(support, filters[index]),
                            ),
                          ),
                  );
                },
              ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.filter, required this.onTap});

  final ServerFilter filter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final expired = filter.isExpiredAt(DateTime.now());
    final contexts = FilterContext.values
        .where(filter.contexts.contains)
        .map(filterContextLabel)
        .join('・');
    final details = [
      filterActionLabel(filter.action),
      if (contexts.isNotEmpty) contexts,
      'キーワード ${filter.keywords.length} 件',
      if (expired)
        '期限切れ'
      else if (filter.expiresAt case final at?)
        '${_formatExpiry(at.toLocal())} まで',
    ].join(' ／ ');
    final mutedColor = Theme.of(context).disabledColor;
    return ListTile(
      leading: const Icon(Icons.filter_alt_outlined),
      title: Text(
        filter.title,
        style: expired ? TextStyle(color: mutedColor) : null,
      ),
      subtitle: Text(details),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  static String _formatExpiry(DateTime at) =>
      '${at.month}/${at.day} ${at.hour}:${at.minute.toString().padLeft(2, '0')}';
}

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/channel_provider.dart';
import '../util/deck_navigation.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/channel_actions_sheet.dart';
import '../widget/retry_error_view.dart';

/// チャンネルを探す・管理する画面 (#1051)。
///
/// ドロワーのクイックチューザ（`pickFollowedChannel`）の奥に置く。
class ChannelManagementScreen extends ConsumerStatefulWidget {
  const ChannelManagementScreen({super.key});

  @override
  ConsumerState<ChannelManagementScreen> createState() =>
      _ChannelManagementScreenState();
}

class _ChannelManagementScreenState
    extends ConsumerState<ChannelManagementScreen>
    with SingleTickerProviderStateMixin {
  final _search = TextEditingController();
  late final TabController _tabs = TabController(
    length: ChannelListKind.values.length,
    vsync: this,
  );
  String _query = '';

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final saved = await context.push<bool>('/channels/edit');
    if (saved != true || !mounted) return;
    invalidateChannels(ref);
    // 作ったものが見えるタブへ移る。他のタブのままだと、作れていないように見える。
    _clearSearch();
    _tabs.animateTo(ChannelListKind.values.indexOf(ChannelListKind.owned));
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('チャンネル'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新規作成',
            onPressed: _create,
          ),
        ],
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
                  hintText: 'チャンネルを検索',
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
                child: _ChannelList(
                  provider: channelSearchProvider(_query),
                  emptyMessage: '見つかりませんでした',
                ),
              )
            else ...[
              TabBar(
                controller: _tabs,
                tabs: [
                  for (final kind in ChannelListKind.values)
                    Tab(text: kind.label),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    for (final kind in ChannelListKind.values)
                      _ChannelList(
                        provider: channelListProvider(kind),
                        emptyMessage: '${kind.label}のチャンネルはありません',
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

class _ChannelList extends ConsumerWidget {
  const _ChannelList({required this.provider, required this.emptyMessage});

  final ProviderListenable<AsyncValue<List<Channel>>> provider;
  final String emptyMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channels = ref.watch(provider);
    return channels.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => RetryErrorView(
        message: '読み込みに失敗しました',
        isRetrying: channels.isLoading,
        onRetry: () => invalidateChannels(ref),
      ),
      data: (list) {
        if (list.isEmpty) return Center(child: Text(emptyMessage));
        return ListView.separated(
          itemCount: list.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final channel = list[index];
            final description = channel.description;
            return ListTile(
              leading: Icon(
                channel.isFollowing ? Icons.forum : Icons.forum_outlined,
              ),
              title: Text(
                channel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: description == null || description.isEmpty
                  ? null
                  : Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
              onTap: () => openChannel(context, channel.id, channel.name),
              trailing: IconButton(
                icon: const Icon(Icons.more_horiz),
                tooltip: 'チャンネルの操作',
                onPressed: () => showChannelActions(context, ref, channel),
              ),
            );
          },
        );
      },
    );
  }
}

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';

final _scheduledPostsProvider = FutureProvider.autoDispose<List<ScheduledPost>>(
  (ref) async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null || adapter is! ScheduleSupport) return [];
    return (adapter as ScheduleSupport).getScheduledPosts();
  },
);

class ScheduledPostsScreen extends ConsumerWidget {
  const ScheduledPostsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final postsAsync = ref.watch(_scheduledPostsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('予約投稿')),
      body: postsAsync.when(
        data: (posts) {
          if (posts.isEmpty) {
            return const Center(child: Text('予約投稿はありません'));
          }
          return ListView.builder(
            itemCount: posts.length,
            itemBuilder: (context, index) {
              final post = posts[index];
              return _ScheduledPostTile(
                post: post,
                onCancel: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('予約投稿の取り消し'),
                      content: const Text('この予約投稿を取り消しますか？'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('キャンセル'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('取り消す'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) return;

                  final adapter = ref.read(currentAdapterProvider);
                  if (adapter is ScheduleSupport) {
                    try {
                      await (adapter as ScheduleSupport).cancelScheduledPost(
                        post.id,
                      );
                      ref.invalidate(_scheduledPostsProvider);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('予約投稿を取り消しました')),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('取り消しに失敗しました')),
                        );
                      }
                    }
                  }
                },
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('読み込みに失敗しました')),
      ),
    );
  }
}

class _ScheduledPostTile extends StatelessWidget {
  final ScheduledPost post;
  final VoidCallback onCancel;

  const _ScheduledPostTile({required this.post, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final dt = post.scheduledAt.toLocal();
    final dateStr =
        '${dt.year}/${dt.month}/${dt.day} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';

    return ListTile(
      title: Text(
        post.content ?? '（本文なし）',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(dateStr),
      leading: const Icon(Icons.schedule),
      trailing: IconButton(
        icon: const Icon(Icons.cancel_outlined),
        tooltip: '取り消す',
        onPressed: onCancel,
      ),
    );
  }
}

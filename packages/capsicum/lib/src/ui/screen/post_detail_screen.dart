import 'dart:io';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../widget/post_tile.dart';

class PostDetailScreen extends ConsumerWidget {
  final Post post;

  const PostDetailScreen({super.key, required this.post});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threadFuture = ref.watch(_threadProvider(post.id));

    return Scaffold(
      appBar: AppBar(
        title: const Text('スレッド'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _buildBody(context, ref, threadFuture),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<Post>> threadFuture,
  ) {
    final storageKey = ref.watch(currentAccountProvider)?.key.toStorageKey();
    final bgPath = storageKey != null
        ? ref.watch(backgroundImageProvider(storageKey))
        : null;
    final bgOpacity = storageKey != null
        ? ref.watch(backgroundOpacityProvider(storageKey))
        : defaultBackgroundOpacity;

    Widget body = threadFuture.when(
      data: (thread) => ListView.separated(
        itemCount: thread.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final p = thread[index];
          final isTarget = p.id == post.id;
          return Container(
            color: isTarget
                ? Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.3)
                : null,
            child: PostTile(
              post: p,
              tappable: !isTarget,
              initialExpanded: isTarget,
              selectable: true,
              onActionCompleted: () => ref.invalidate(_threadProvider(post.id)),
            ),
          );
        },
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('スレッドの読み込みに失敗しました\n$error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.invalidate(_threadProvider(post.id)),
                child: const Text('再試行'),
              ),
            ],
          ),
        ),
      ),
    );

    if (bgPath != null) {
      body = Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: FileImage(File(bgPath)),
            fit: BoxFit.cover,
            opacity: bgOpacity,
          ),
        ),
        child: body,
      );
    }

    return body;
  }
}

final _threadProvider = FutureProvider.autoDispose.family<List<Post>, String>((
  ref,
  postId,
) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter == null) return [];
  return adapter.getThread(postId);
});

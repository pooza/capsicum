import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/gallery_provider.dart';

class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(galleryPostsProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final gallery = ref.watch(galleryPostsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ギャラリー'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: gallery.when(
        data: (state) => state.posts.isEmpty
            ? const Center(child: Text('ギャラリー投稿はありません'))
            : RefreshIndicator(
                onRefresh: () => ref.refresh(galleryPostsProvider.future),
                child: ListView.separated(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(8),
                  itemCount: state.posts.length + (state.isLoadingMore ? 1 : 0),
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    if (index >= state.posts.length) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    return _GalleryCard(post: state.posts[index]);
                  },
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('読み込みに失敗しました', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref.invalidate(galleryPostsProvider),
                  child: const Text('再試行'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GalleryCard extends StatelessWidget {
  final GalleryPost post;

  const _GalleryCard({required this.post});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumbnail = post.files.isNotEmpty
        ? post.files.first.previewUrl ?? post.files.first.url
        : null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/gallery/${post.id}', extra: post),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (thumbnail != null)
              AspectRatio(
                aspectRatio: 16 / 9,
                child: post.isSensitive
                    ? Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.visibility_off, size: 32),
                              SizedBox(height: 4),
                              Text('閲覧注意'),
                            ],
                          ),
                        ),
                      )
                    : Image.network(
                        thumbnail,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: const Center(child: Icon(Icons.broken_image)),
                        ),
                      ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    post.title,
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (post.author.avatarUrl != null) ...[
                        CircleAvatar(
                          radius: 10,
                          backgroundImage: NetworkImage(post.author.avatarUrl!),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          post.author.displayName ?? post.author.username,
                          style: theme.textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (post.files.length > 1)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.photo_library,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '${post.files.length}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

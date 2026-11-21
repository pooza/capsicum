import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/gallery_provider.dart';
import '../util/deck_navigation.dart';
import '../util/notification_type_display.dart'
    show contentWarningFallbackLabel;
import '../util/scroll_thresholds.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/retry_error_view.dart';

class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  final _scrollController = ScrollController();

  /// 注目と新着のどちらを見ているか (#1053)。既定は従来どおり注目。
  var _kind = GalleryListKind.featured;

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
    if (shouldLoadMore(_scrollController.position)) {
      ref.read(galleryPostsProvider(_kind).notifier).loadMore();
    }
  }

  void _select(GalleryListKind kind) {
    if (kind == _kind) return;
    setState(() => _kind = kind);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final provider = galleryPostsProvider(_kind);
    final gallery = ref.watch(provider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ギャラリー'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // 注目 / 新着 (#1053)。
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SegmentedButton<GalleryListKind>(
              segments: const [
                ButtonSegment(
                  value: GalleryListKind.featured,
                  label: Text('注目'),
                ),
                ButtonSegment(value: GalleryListKind.recent, label: Text('新着')),
              ],
              selected: {_kind},
              showSelectedIcon: false,
              onSelectionChanged: (s) => _select(s.first),
            ),
          ),
        ),
      ),
      body: BottomSafeArea(
        child: gallery.when(
          data: (state) => state.posts.isEmpty
              ? const Center(child: Text('ギャラリー投稿はありません'))
              : RefreshIndicator(
                  onRefresh: () => ref.refresh(provider.future),
                  child: ListView.separated(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(8),
                    itemCount:
                        state.posts.length + (state.isLoadingMore ? 1 : 0),
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
          error: (error, stack) => RetryErrorView(
            message: '読み込みに失敗しました',
            isRetrying: gallery.isLoading,
            onRetry: () => ref.invalidate(provider),
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
        onTap: () => openGalleryPost(context, post),
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
                              Text(contentWarningFallbackLabel),
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

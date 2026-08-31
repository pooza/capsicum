import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/bookmark_provider.dart';
import '../../provider/server_config_provider.dart';
import '../util/op_error.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/post_tile.dart';
import '../widget/retry_error_view.dart';

class BookmarkScreen extends ConsumerStatefulWidget {
  const BookmarkScreen({super.key});

  @override
  ConsumerState<BookmarkScreen> createState() => _BookmarkScreenState();
}

class _BookmarkScreenState extends ConsumerState<BookmarkScreen> {
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
        _scrollController.position.maxScrollExtent - 600) {
      ref.read(bookmarkProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = ref.watch(bookmarkLabelProvider);
    final emptyMessage = '$titleはありません';
    final bookmarks = ref.watch(bookmarkProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: BottomSafeArea(
        child: bookmarks.when(
          data: (state) => state.posts.isEmpty
              ? Center(child: Text(emptyMessage))
              : RefreshIndicator(
                  onRefresh: () => ref.refresh(bookmarkProvider.future),
                  child: ListView.separated(
                    controller: _scrollController,
                    itemCount:
                        state.posts.length + (state.isLoadingMore ? 1 : 0),
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      if (index >= state.posts.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      return PostTile(post: state.posts[index]);
                    },
                  ),
                ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => RetryErrorView(
            message: '$titleの読み込みに失敗しました\n${summarizeOpError(error)}',
            isRetrying: bookmarks.isLoading,
            onRetry: () => ref.invalidate(bookmarkProvider),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/favorite_provider.dart';
import '../../provider/server_config_provider.dart';
import '../util/op_error.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/post_tile.dart';
import '../widget/retry_error_view.dart';

/// お気に入りした投稿の一覧 (#1071)。
///
/// ⚠ **「付ける」側だけ実装して「見る」側が無かった。**同じ「あとで見る」系で
/// ブックマークにだけ一覧があるという非対称になっていた。様式はブックマーク
/// 画面（[BookmarkScreen]）の隣に 1 枚足す形に揃えてある。
///
/// ⚠ **モロヘイヤの「お気に入りタグ」とは別物。**あちらは投稿に付ける
/// ハッシュタグの管理機能で、Mastodon の favourite とは無関係。UI 文言が
/// 紛れないよう、こちらは「お気に入り」とだけ呼ぶ。
///
/// ⚠ **Mastodon 固有。**Misskey の「お気に入り」は意味的にブックマーク相当で、
/// capsicum は `/bookmarks` へ寄せてある。
class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen> {
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
      ref.read(favoriteProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final favorites = ref.watch(favoriteProvider);
    // ⚠ **文言を直書きしない (#1083-F)。**用語の正本は provider 側
    // （#1027-C2）。現状の表示は直書きと一致するが、`FavoriteSupport` と
    // `ReactionSupport` を両方持つアダプターが入ると、カウントチップ
    // （provider 由来「リアクション」）とこの画面が同じ機能に別名を付ける。
    final label = ref.watch(favouriteLabelProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(label),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: BottomSafeArea(
        child: favorites.when(
          data: (state) => state.posts.isEmpty
              ? Center(child: Text('$labelはありません'))
              : RefreshIndicator(
                  onRefresh: () => ref.refresh(favoriteProvider.future),
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
            message: '$labelの読み込みに失敗しました\n${summarizeOpError(error)}',
            isRetrying: favorites.isLoading,
            onRetry: () => ref.invalidate(favoriteProvider),
          ),
        ),
      ),
    );
  }
}

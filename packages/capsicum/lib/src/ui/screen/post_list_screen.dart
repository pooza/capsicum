import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../util/exception_scrub.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/post_tile.dart';

/// 投稿一覧をカーソルページングで出す汎用画面 (#1072)。
///
/// ⚠ **`/users`（[UserListScreen]）の投稿版。**ブースト一覧・お気に入り一覧は
/// 「その投稿に反応した**人**」なのでユーザー一覧で足りるが、引用は
/// 「その投稿を引用した**投稿**」なので中身が違う。そのまま流用できない。
typedef PostListFetcher =
    Future<({List<Post> posts, String? nextCursor})> Function(String? cursor);

class PostListScreen extends ConsumerStatefulWidget {
  final String title;
  final PostListFetcher fetcher;

  /// 一覧が空のときの文言。
  final String emptyMessage;

  const PostListScreen({
    super.key,
    required this.title,
    required this.fetcher,
    this.emptyMessage = '投稿はありません',
  });

  @override
  ConsumerState<PostListScreen> createState() => _PostListScreenState();
}

class _PostListScreenState extends ConsumerState<PostListScreen> {
  static const _pageSize = 20;

  final _scrollController = ScrollController();
  List<Post> _posts = [];
  String? _nextCursor;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    try {
      final result = await widget.fetcher(null);
      if (!mounted) return;
      setState(() {
        _posts = result.posts;
        _nextCursor = result.nextCursor;
        _loading = false;
        _hasMore =
            result.nextCursor != null && result.posts.length >= _pageSize;
      });
    } catch (e) {
      debugLogException('PostListScreen load error', e);
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _posts.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final result = await widget.fetcher(_nextCursor);
      if (!mounted) return;
      setState(() {
        _posts = [..._posts, ...result.posts];
        _nextCursor = result.nextCursor;
        _loadingMore = false;
        _hasMore =
            result.nextCursor != null && result.posts.length >= _pageSize;
      });
    } catch (e) {
      debugLogException('PostListScreen loadMore error', e);
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: BottomSafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _posts.isEmpty
            ? Center(child: Text(widget.emptyMessage))
            : RefreshIndicator(
                onRefresh: () async {
                  setState(() => _loading = true);
                  await _load();
                },
                child: ListView.separated(
                  controller: _scrollController,
                  itemCount: _posts.length + (_loadingMore ? 1 : 0),
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    if (index >= _posts.length) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    return PostTile(post: _posts[index]);
                  },
                ),
              ),
      ),
    );
  }
}

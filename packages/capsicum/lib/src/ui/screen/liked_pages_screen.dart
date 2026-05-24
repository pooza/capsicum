import 'package:capsicum_core/capsicum_core.dart' as cc;
import 'package:capsicum_core/capsicum_core.dart' hide Page;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../widget/page_card.dart';

/// 「いいねしたページ」一覧画面 (#186)。
///
/// Misskey の `i/page-likes` を叩いて、認証ユーザーが like 済みのページを
/// 一覧表示する。各カードのタップで [PageViewScreen] へ遷移 (PageCard 経由)。
class LikedPagesScreen extends ConsumerStatefulWidget {
  const LikedPagesScreen({super.key});

  @override
  ConsumerState<LikedPagesScreen> createState() => _LikedPagesScreenState();
}

class _LikedPagesScreenState extends ConsumerState<LikedPagesScreen> {
  final _scrollController = ScrollController();
  List<cc.Page> _pages = [];
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
    _scrollController.removeListener(_onScroll);
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
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! PagesSupport) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final pages = await (adapter as PagesSupport).getLikedPages(
        query: const TimelineQuery(limit: 20),
      );
      if (mounted) {
        setState(() {
          _pages = pages;
          _loading = false;
          _hasMore = pages.length >= 20;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _pages.isEmpty) return;
    setState(() => _loadingMore = true);

    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! PagesSupport) {
      if (mounted) setState(() => _loadingMore = false);
      return;
    }
    try {
      final older = await (adapter as PagesSupport).getLikedPages(
        query: TimelineQuery(maxId: _pages.last.id, limit: 20),
      );
      if (mounted) {
        setState(() {
          _pages = [..._pages, ...older];
          _loadingMore = false;
          _hasMore = older.length >= 20;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('いいねしたページ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_pages.isEmpty) {
      return const Center(child: Text('いいねしたページはありません'));
    }
    return RefreshIndicator(
      onRefresh: () async {
        setState(() {
          _loading = true;
          _pages = [];
          _hasMore = true;
        });
        await _load();
      },
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(8),
        itemCount: _pages.length + (_loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _pages.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return PageCard(page: _pages[index]);
        },
      ),
    );
  }
}

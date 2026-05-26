import 'package:capsicum_core/capsicum_core.dart' as cc;
import 'package:capsicum_core/capsicum_core.dart' hide Page;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../provider/account_manager_provider.dart';
import '../../service/exception_scrub.dart';
import '../widget/page_card.dart';

/// Misskey ページのハブ画面 (#186)。
///
/// v1 では「いいねしたページ」のみ表示。将来 WebUI の『人気』(`pages/featured`、
/// API は Phase A で実装済み) や『自分のページ』(`users/pages` / `i/pages`) を
/// 同画面に追加する想定で、本画面はセクション見出し付きの ListView で
/// 構成している。後段で TabBar 化する選択肢も残す。
class PagesScreen extends ConsumerStatefulWidget {
  const PagesScreen({super.key});

  @override
  ConsumerState<PagesScreen> createState() => _PagesScreenState();
}

class _PagesScreenState extends ConsumerState<PagesScreen> {
  final _scrollController = ScrollController();
  List<cc.Page> _likedPages = [];
  bool _loadingLiked = true;
  bool _loadingMoreLiked = false;
  bool _hasMoreLiked = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadLiked();
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
      _loadMoreLiked();
    }
  }

  Future<void> _loadLiked() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! PagesSupport) {
      if (mounted) setState(() => _loadingLiked = false);
      return;
    }
    try {
      final pages = await (adapter as PagesSupport).getLikedPages(
        query: const TimelineQuery(limit: 20),
      );
      if (mounted) {
        setState(() {
          _likedPages = pages;
          _loadingLiked = false;
          _hasMoreLiked = pages.length >= 20;
        });
      }
    } catch (e, st) {
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('pages.op', 'load_liked');
        },
      );
      if (!mounted) return;
      setState(() => _loadingLiked = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('いいねしたページの読み込みに失敗しました')));
    }
  }

  Future<void> _loadMoreLiked() async {
    if (_loadingMoreLiked || !_hasMoreLiked || _likedPages.isEmpty) return;
    setState(() => _loadingMoreLiked = true);

    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! PagesSupport) {
      if (mounted) setState(() => _loadingMoreLiked = false);
      return;
    }
    try {
      final older = await (adapter as PagesSupport).getLikedPages(
        query: TimelineQuery(maxId: _likedPages.last.id, limit: 20),
      );
      if (mounted) {
        setState(() {
          _likedPages = [..._likedPages, ...older];
          _loadingMoreLiked = false;
          _hasMoreLiked = older.length >= 20;
        });
      }
    } catch (e, st) {
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('pages.op', 'load_more_liked');
        },
      );
      if (!mounted) return;
      setState(() => _loadingMoreLiked = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('追加読み込みに失敗しました')));
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loadingLiked = true;
      _likedPages = [];
      _hasMoreLiked = true;
    });
    await _loadLiked();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ページ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: RefreshIndicator(onRefresh: _refresh, child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loadingLiked) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Text(
              'いいねしたページ',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
        if (_likedPages.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('いいねしたページはありません'),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                if (index >= _likedPages.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return PageCard(page: _likedPages[index]);
              }, childCount: _likedPages.length + (_loadingMoreLiked ? 1 : 0)),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

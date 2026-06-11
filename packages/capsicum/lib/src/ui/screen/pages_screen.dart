import 'package:capsicum_core/capsicum_core.dart';
// Flutter material の `Page` (Navigator) と capsicum_core の `Page` が衝突する
// ため Flutter 側を hide する。本画面では Misskey ページのみ扱う。
import 'package:flutter/material.dart' hide Page;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../util/pages_error.dart';
import '../widget/page_card.dart';

/// Misskey ページのハブ画面 (#186)。
///
/// 「人気」(`pages/featured`, #617) と「いいねしたページ」(`i/page-likes`) の
/// 2 セクションをセクション見出し付きの単一スクロールで構成する。人気は
/// 単一ページ取得 (ページネーションなし) のため上部に固定ブロックとして置き、
/// 無限スクロールするいいね一覧を下に残すことで両者のページネーションが
/// 競合しないようにしている。将来「自分のページ」追加や TabBar 化の余地は残す。
class PagesScreen extends ConsumerStatefulWidget {
  const PagesScreen({super.key});

  @override
  ConsumerState<PagesScreen> createState() => _PagesScreenState();
}

class _PagesScreenState extends ConsumerState<PagesScreen> {
  final _scrollController = ScrollController();
  // ライクエントリ単位で保持する (#631)。pagination cursor として渡すべきは
  // ページ ID ではなく `LikedPageEntry.likeId` の方。
  List<LikedPageEntry> _likedEntries = [];
  bool _loadingLiked = true;
  bool _loadingMoreLiked = false;
  bool _hasMoreLiked = true;
  // 人気ページ (#617)。pages/featured は単一ページ取得なので追加読み込みは
  // 持たず、limit 件を先頭ブロックとして表示するだけ。
  List<Page> _featuredPages = [];
  bool _loadingFeatured = true;
  static const _featuredLimit = 30;
  // _refresh が走った瞬間に in-flight の _loadMoreLiked が古い cursor 由来
  // の結果を空配列にマージしてしまう race を防ぐ generation token (#631)。
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadLiked();
    _loadFeatured();
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
      final entries = await (adapter as PagesSupport).getLikedPages(
        query: const TimelineQuery(limit: 20),
      );
      if (mounted) {
        setState(() {
          _likedEntries = entries;
          _loadingLiked = false;
          _hasMoreLiked = entries.length >= 20;
        });
      }
    } catch (e, st) {
      reportPagesOpFailure(
        'load_liked',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (!mounted) return;
      setState(() => _loadingLiked = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('いいねしたページの読み込みに失敗しました')));
    }
  }

  Future<void> _loadMoreLiked() async {
    if (_loadingMoreLiked || !_hasMoreLiked || _likedEntries.isEmpty) return;
    final gen = _loadGeneration;
    setState(() => _loadingMoreLiked = true);

    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! PagesSupport) {
      if (mounted && gen == _loadGeneration) {
        setState(() => _loadingMoreLiked = false);
      }
      return;
    }
    try {
      final older = await (adapter as PagesSupport).getLikedPages(
        query: TimelineQuery(maxId: _likedEntries.last.likeId, limit: 20),
      );
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _likedEntries = [..._likedEntries, ...older];
        _loadingMoreLiked = false;
        _hasMoreLiked = older.length >= 20;
      });
    } catch (e, st) {
      reportPagesOpFailure(
        'load_more_liked',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (!mounted || gen != _loadGeneration) return;
      setState(() => _loadingMoreLiked = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('追加読み込みに失敗しました')));
    }
  }

  Future<void> _loadFeatured() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! PagesSupport) {
      if (mounted) setState(() => _loadingFeatured = false);
      return;
    }
    try {
      final pages = await (adapter as PagesSupport).getFeaturedPages(
        query: const TimelineQuery(limit: _featuredLimit),
      );
      if (mounted) {
        setState(() {
          _featuredPages = pages;
          _loadingFeatured = false;
        });
      }
    } catch (e, st) {
      reportPagesOpFailure(
        'load_featured',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (!mounted) return;
      // 人気は補助セクションなので失敗してもいいね一覧は出す。SnackBar は出さず
      // 見出しごと畳む (空表示)。詳細は Sentry 側で追う。
      setState(() {
        _featuredPages = [];
        _loadingFeatured = false;
      });
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loadGeneration++;
      _loadingLiked = true;
      _loadingMoreLiked = false;
      _likedEntries = [];
      _hasMoreLiked = true;
      _loadingFeatured = true;
      _featuredPages = [];
    });
    await Future.wait([_loadLiked(), _loadFeatured()]);
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
    // 人気・いいねの両方がまだ初回ロード中のときだけ全画面スピナー。どちらかが
    // 返ったら下のセクション内でそれぞれの状態を出す。
    if (_loadingLiked && _loadingFeatured) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        ..._buildFeaturedSlivers(theme),
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
        if (_loadingLiked)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (_likedEntries.isEmpty)
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
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  if (index >= _likedEntries.length) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  return PageCard(page: _likedEntries[index].page);
                },
                childCount: _likedEntries.length + (_loadingMoreLiked ? 1 : 0),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  /// 「人気」セクション (#617)。ロード中はスピナー、結果が空なら見出しごと
  /// 畳む (補助セクションのため場所を取らせない)。
  List<Widget> _buildFeaturedSlivers(ThemeData theme) {
    if (_loadingFeatured) {
      return [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    if (_featuredPages.isEmpty) return const [];
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        sliver: SliverToBoxAdapter(
          child: Text(
            '人気',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => PageCard(page: _featuredPages[index]),
            childCount: _featuredPages.length,
          ),
        ),
      ),
    ];
  }
}

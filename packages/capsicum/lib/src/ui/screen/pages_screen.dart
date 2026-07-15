import 'package:capsicum_core/capsicum_core.dart';
// Flutter material の `Page` (Navigator) と capsicum_core の `Page` が衝突する
// ため Flutter 側を hide する。本画面では Misskey ページのみ扱う。
import 'package:flutter/material.dart' hide Page;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../util/oauth_scope_error.dart';
import '../util/pages_error.dart';
import '../widget/oauth_scope_error_view.dart';
import '../widget/page_card.dart';

/// Misskey ページのハブ画面 (#186)。
///
/// 「自分のページ」(`users/pages` に self id, #618) と「人気」
/// (`pages/featured`, #617) と「いいねしたページ」(`i/page-likes`) の
/// 3 セクションをセクション見出し付きの単一スクロールで構成する。自分のページと
/// 人気は単一ページ取得 (ページネーションなし) のため上部に固定ブロックとして
/// 置き、無限スクロールするいいね一覧を下に残すことで両者のページネーションが
/// 競合しないようにしている。自分のページの全件ページネーションはプロフィール →
/// ページタブが担う。将来 TabBar 化の余地は残す。
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
  // いいね一覧の取得が OAuth スコープ不足 (read:page-likes 未付与の旧トークン)
  // で失敗したか。汎用エラーではなく再ログイン誘導を出すための分岐 (#615)。
  bool _likedScopeError = false;
  // 人気ページ (#617)。pages/featured は単一ページ取得なので追加読み込みは
  // 持たず、limit 件を先頭ブロックとして表示するだけ。
  List<Page> _featuredPages = [];
  bool _loadingFeatured = true;
  static const _featuredLimit = 30;
  // 自分のページ (#618)。プロフィール → ページタブが全件ページネーションを
  // 担うため、ハブ側は先頭 limit 件の軽量ブロックに留める (人気と同構造)。
  List<Page> _myPages = [];
  bool _loadingMyPages = true;
  static const _myPagesLimit = 30;
  // _refresh が走った瞬間に in-flight の _loadMoreLiked が古い cursor 由来
  // の結果を空配列にマージしてしまう race を防ぐ generation token (#631)。
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadLiked();
    _loadFeatured();
    _loadMyPages();
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
          _likedScopeError = false;
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
      // 旧トークン (read:page-likes 未付与) は 403 PERMISSION_DENIED で失敗する。
      // 汎用 SnackBar ではなく再ログイン誘導 (OAuthScopeErrorView) を出す (#615)。
      final scopeError = isOAuthScopeError(e);
      setState(() {
        _loadingLiked = false;
        _likedScopeError = scopeError;
      });
      if (!scopeError) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('いいねしたページの読み込みに失敗しました')));
      }
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

  Future<void> _loadMyPages() async {
    final adapter = ref.read(currentAdapterProvider);
    final account = ref.read(currentAccountProvider);
    if (adapter is! PagesSupport || account == null) {
      if (mounted) setState(() => _loadingMyPages = false);
      return;
    }
    try {
      final pages = await (adapter as PagesSupport).getUserPages(
        account.user.id,
        query: const TimelineQuery(limit: _myPagesLimit),
      );
      if (mounted) {
        setState(() {
          _myPages = pages;
          _loadingMyPages = false;
        });
      }
    } catch (e, st) {
      reportPagesOpFailure(
        'load_my_pages',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (!mounted) return;
      // 自分のページも補助セクション扱い。失敗しても他セクションは出すため
      // SnackBar は出さず見出しごと畳む (詳細は Sentry で追う)。
      setState(() {
        _myPages = [];
        _loadingMyPages = false;
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
      _likedScopeError = false;
      _loadingFeatured = true;
      _featuredPages = [];
      _loadingMyPages = true;
      _myPages = [];
    });
    await Future.wait([_loadLiked(), _loadFeatured(), _loadMyPages()]);
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
    // 全セクションがまだ初回ロード中のときだけ全画面スピナー。どれかが返ったら
    // 下のセクション内でそれぞれの状態を出す。
    if (_loadingLiked && _loadingFeatured && _loadingMyPages) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        // 自分のページ (#618) を先頭に。最も個人的なセクションなので上に置く。
        ..._buildFixedBlockSlivers(theme, '自分のページ', _loadingMyPages, _myPages),
        ..._buildFixedBlockSlivers(
          theme,
          '人気',
          _loadingFeatured,
          _featuredPages,
        ),
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
        else if (_likedScopeError)
          // 旧トークンでスコープ不足。人気セクションはスコープ不要で出せるので
          // 残し、いいね一覧の枠にだけ再ログイン誘導を出す (#615)。
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: OAuthScopeErrorView(),
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

  /// 追加読み込みを持たない固定ブロックのセクション (人気 #617 / 自分のページ
  /// #618)。ロード中はスピナー、結果が空なら見出しごと畳む (補助セクションの
  /// ため場所を取らせない)。無限スクロールする「いいねしたページ」とは別扱いで、
  /// ページネーションの競合を避けるため先頭に固定ブロックとして並べる。
  List<Widget> _buildFixedBlockSlivers(
    ThemeData theme,
    String title,
    bool loading,
    List<Page> pages,
  ) {
    if (loading) {
      return [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    if (pages.isEmpty) return const [];
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        sliver: SliverToBoxAdapter(
          child: Text(
            title,
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
            (context, index) => PageCard(page: pages[index]),
            childCount: pages.length,
          ),
        ),
      ),
    ];
  }
}

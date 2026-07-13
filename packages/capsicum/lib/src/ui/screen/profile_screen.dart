import 'package:capsicum_core/capsicum_core.dart' as cc;
import 'package:capsicum_core/capsicum_core.dart' hide Page;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../constants.dart';
import '../../url_helper.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/is_cat_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../provider/supporter_status_provider.dart';
import '../../provider/timeline_provider.dart';
import '../../service/server_version_checker.dart';
import '../../service/tco_resolver.dart';
import '../util/fediverse_link.dart';
import '../widget/server_badge.dart';
import '../widget/content_parser.dart';
import '../widget/emoji_text.dart';
import '../widget/page_card.dart';
import '../widget/post_tile.dart';
import '../widget/user_avatar.dart';
import '../util/user_acct.dart';
import '../util/relative_time.dart';

/// プロフィール画面のタブ種別。表示するタブ集合は adapter のケーパビリティと
/// Mastodon 4.6 の show_media 設定（#732）で動的に決まるため、位置インデックスの
/// 直書きをやめ、この列挙で意味付けする。
enum _ProfileTab { posts, media, gallery, pages }

class ProfileScreen extends ConsumerStatefulWidget {
  final User user;

  const ProfileScreen({super.key, required this.user});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
    with TickerProviderStateMixin {
  final _scrollController = ScrollController();
  late TabController _tabController;
  late User _user = widget.user;
  List<Post> _pinnedPosts = [];
  List<Post> _posts = [];
  bool _loadingPosts = true;
  bool _loadingMore = false;
  bool _hasMore = true;

  List<Post> _mediaPosts = [];
  bool _loadingMediaPosts = true;
  bool _loadingMoreMedia = false;
  bool _hasMoreMedia = true;
  bool _mediaTabLoaded = false;

  List<GalleryPost> _galleryPosts = [];
  bool _loadingGallery = true;
  bool _loadingMoreGallery = false;
  bool _hasMoreGallery = true;
  bool _galleryTabLoaded = false;

  List<cc.Page> _pages = [];
  bool _loadingPages = true;
  bool _loadingMorePages = false;
  bool _hasMorePages = true;
  bool _pagesTabLoaded = false;

  bool get _hasGalleryTab => ref.read(currentAdapterProvider) is GallerySupport;
  bool get _hasPagesTab => ref.read(currentAdapterProvider) is PagesSupport;

  /// 表示するタブの順序付きリスト。adapter のケーパビリティに加え、Mastodon 4.6
  /// の show_media 設定（#732）でメディアタブの有無が決まる。show_media が未対応
  /// サーバー（null）や true のときは従来どおりメディアタブを出す。
  List<_ProfileTab> get _visibleTabs => [
    _ProfileTab.posts,
    if (_user.showMedia != false) _ProfileTab.media,
    if (_hasGalleryTab) _ProfileTab.gallery,
    if (_hasPagesTab) _ProfileTab.pages,
  ];

  static const _tabLabels = <_ProfileTab, String>{
    _ProfileTab.posts: '投稿',
    _ProfileTab.media: 'メディア',
    _ProfileTab.gallery: 'ギャラリー',
    _ProfileTab.pages: 'ページ',
  };

  UserRelationship? _relationship;
  bool _relationshipLoading = false;

  bool get _isOwnProfile {
    final current = ref.read(currentAccountProvider);
    return current != null && current.user.id == widget.user.id;
  }

  /// 「メッセージを送る」ボタンを出してよいか。
  /// - 現アカウントが ChatSupport かつ canWriteChat == true（自分のロールが
  ///   送信可能。readonly では false）
  /// - 相手の canChat == true（相手のロールが chat 可能）
  /// - リモートユーザー（host が現サーバーと違う）は対象外。Misskey の
  ///   chat は同一サーバー内でのみ成立する仕様
  bool _canStartChatWith(User user) {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ChatSupport) return false;
    if (!(adapter as ChatSupport).canWriteChat) return false;
    if (user.canChat != true) return false;
    final account = ref.read(currentAccountProvider);
    if (account == null) return false;
    if (user.host != null && user.host != account.key.host) return false;
    return true;
  }

  static final _tcoPattern = RegExp(r'https?://t\.co/\S+');
  ContentRenderer? _bioRenderer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _visibleTabs.length, vsync: this);
    _tabController.addListener(_onTabChanged);
    _scrollController.addListener(_onScroll);
    _fetchFullUser();
    _loadPinnedPosts();
    _loadPosts();
    _loadRelationship();
    _resolveTcoUrls();
  }

  void _resolveTcoUrls() {
    final texts = [
      if (widget.user.description != null) _stripHtml(widget.user.description!),
      ...widget.user.fields.map((f) => _stripHtml(f.value)),
    ];
    for (final text in texts) {
      for (final match in _tcoPattern.allMatches(text)) {
        final url = match.group(0)!;
        if (TcoResolver.getCached(url) != null) continue;
        TcoResolver.resolve(url).then((resolved) {
          if (resolved != null && mounted) setState(() {});
        });
      }
    }
  }

  void _onTabChanged() {
    // タブ切替でコンテンツ sliver（_buildTabContent は _tabController.index を
    // 参照）を追従させるため、settle 時に rebuild する。
    if (!_tabController.indexIsChanging && mounted) setState(() {});
    final tabs = _visibleTabs;
    if (_tabController.index >= tabs.length) return;
    switch (tabs[_tabController.index]) {
      case _ProfileTab.media:
        if (!_mediaTabLoaded) _loadMediaPosts();
      case _ProfileTab.gallery:
        if (!_galleryTabLoaded) _loadGalleryPosts();
      case _ProfileTab.pages:
        if (!_pagesTabLoaded) _loadPages();
      case _ProfileTab.posts:
        break;
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _bioRenderer?.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 600) {
      final tabs = _visibleTabs;
      if (_tabController.index >= tabs.length) return;
      switch (tabs[_tabController.index]) {
        case _ProfileTab.posts:
          _loadMorePosts();
        case _ProfileTab.media:
          _loadMoreMediaPosts();
        case _ProfileTab.gallery:
          _loadMoreGalleryPosts();
        case _ProfileTab.pages:
          _loadMorePages();
      }
    }
  }

  Future<void> _loadPinnedPosts() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;
    try {
      final posts =
          await (adapter as dynamic).getPinnedPosts(widget.user.id)
              as List<Post>;
      if (mounted) setState(() => _pinnedPosts = posts);
    } catch (_) {
      // ピン留め投稿非対応の場合は無視して続行。
    }
  }

  void _onPostUpdated(Post updated) {
    setState(() {
      if (updated.pinned) {
        // ピン留め: リストになければ先頭に追加し、通常リストから除去
        if (!_pinnedPosts.any((p) => p.id == updated.id)) {
          _pinnedPosts = [updated, ..._pinnedPosts];
        }
        _posts = _posts.where((p) => p.id != updated.id).toList();
      } else {
        // ピン留め解除: ピン留めリストから除去し、通常リストに復元
        _pinnedPosts = _pinnedPosts.where((p) => p.id != updated.id).toList();
        if (!_posts.any((p) => p.id == updated.id)) {
          _posts = [updated, ..._posts];
        }
      }
    });
  }

  Future<void> _loadPosts() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    try {
      final posts = await _fetchUserPosts(adapter);
      if (mounted) {
        setState(() {
          final pinnedIds = _pinnedPosts.map((p) => p.id).toSet();
          _posts = posts.where((p) => !pinnedIds.contains(p.id)).toList();
          _loadingPosts = false;
          _hasMore = posts.length >= 20;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingPosts = false);
    }
  }

  Future<void> _loadMorePosts() async {
    if (_loadingMore || !_hasMore || _posts.isEmpty) return;

    setState(() => _loadingMore = true);

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    try {
      final older = await _fetchUserPosts(adapter, maxId: _posts.last.id);
      if (mounted) {
        setState(() {
          _posts = [..._posts, ...older];
          _loadingMore = false;
          _hasMore = older.length >= 20;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadMediaPosts() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    _mediaTabLoaded = true;
    try {
      final posts = await _fetchUserPosts(
        adapter,
        onlyMedia: true,
        excludeReplies: _excludeMediaReplies,
      );
      if (mounted) {
        setState(() {
          _mediaPosts = posts;
          _loadingMediaPosts = false;
          _hasMoreMedia = posts.length >= 20;
        });
      }
    } catch (e) {
      _mediaTabLoaded = false;
      if (mounted) setState(() => _loadingMediaPosts = false);
    }
  }

  Future<void> _loadMoreMediaPosts() async {
    if (_loadingMoreMedia || !_hasMoreMedia || _mediaPosts.isEmpty) return;

    setState(() => _loadingMoreMedia = true);

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    try {
      final older = await _fetchUserPosts(
        adapter,
        maxId: _mediaPosts.last.id,
        onlyMedia: true,
        excludeReplies: _excludeMediaReplies,
      );
      if (mounted) {
        setState(() {
          _mediaPosts = [..._mediaPosts, ...older];
          _loadingMoreMedia = false;
          _hasMoreMedia = older.length >= 20;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingMoreMedia = false);
    }
  }

  Future<void> _loadGalleryPosts() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! GallerySupport) return;

    _galleryTabLoaded = true;
    try {
      final posts = await (adapter as GallerySupport).getUserGalleryPosts(
        widget.user.id,
        query: const TimelineQuery(limit: 20),
      );
      if (mounted) {
        setState(() {
          _galleryPosts = posts;
          _loadingGallery = false;
          _hasMoreGallery = posts.length >= 20;
        });
      }
    } catch (e) {
      _galleryTabLoaded = false;
      if (mounted) setState(() => _loadingGallery = false);
    }
  }

  Future<void> _loadMoreGalleryPosts() async {
    if (_loadingMoreGallery || !_hasMoreGallery || _galleryPosts.isEmpty) {
      return;
    }

    setState(() => _loadingMoreGallery = true);

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! GallerySupport) return;

    try {
      final older = await (adapter as GallerySupport).getUserGalleryPosts(
        widget.user.id,
        query: TimelineQuery(maxId: _galleryPosts.last.id, limit: 20),
      );
      if (mounted) {
        setState(() {
          _galleryPosts = [..._galleryPosts, ...older];
          _loadingMoreGallery = false;
          _hasMoreGallery = older.length >= 20;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingMoreGallery = false);
    }
  }

  Future<void> _loadPages() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! PagesSupport) return;

    _pagesTabLoaded = true;
    try {
      final pages = await (adapter as PagesSupport).getUserPages(
        widget.user.id,
        query: const TimelineQuery(limit: 20),
      );
      if (mounted) {
        setState(() {
          _pages = pages;
          _loadingPages = false;
          _hasMorePages = pages.length >= 20;
        });
      }
    } catch (e) {
      _pagesTabLoaded = false;
      if (mounted) setState(() => _loadingPages = false);
    }
  }

  Future<void> _loadMorePages() async {
    if (_loadingMorePages || !_hasMorePages || _pages.isEmpty) return;

    setState(() => _loadingMorePages = true);

    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! PagesSupport) return;

    try {
      final older = await (adapter as PagesSupport).getUserPages(
        widget.user.id,
        query: TimelineQuery(maxId: _pages.last.id, limit: 20),
      );
      if (mounted) {
        setState(() {
          _pages = [..._pages, ...older];
          _loadingMorePages = false;
          _hasMorePages = older.length >= 20;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingMorePages = false);
    }
  }

  Future<void> _loadRelationship() async {
    if (_isOwnProfile) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! FollowSupport) return;
    try {
      final rel = await (adapter as FollowSupport).getRelationship(
        widget.user.id,
      );
      if (mounted) setState(() => _relationship = rel);
    } catch (e, st) {
      debugPrint('Failed to load relationship: $e\n$st');
    }
  }

  Future<bool> _performAction(Future<void> Function() action) async {
    if (_relationshipLoading) return false;
    setState(() => _relationshipLoading = true);
    try {
      await action();
      await _loadRelationship();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作に失敗しました')));
      }
      debugPrint('User action error: $e');
      return false;
    } finally {
      if (mounted) setState(() => _relationshipLoading = false);
    }
  }

  Future<void> _fetchFullUser() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    try {
      var fullUser = await adapter.getUserById(widget.user.id);
      fullUser = await ref.read(isCatEnricherProvider).enrichUser(fullUser);
      if (mounted) {
        final excludeRepliesBefore = _excludeMediaReplies;
        setState(() => _user = fullUser);
        // 完全な user 取得で show_media が判明しタブ集合が変わることがある（#732）。
        _syncTabController();
        // メディアタブを先に開いた後で Mastodon 4.6 の show_media_replies=false が
        // 判明した場合、返信添付を含んだ初回結果を破棄して読み直す（#809 race）。
        if (_mediaTabLoaded && _excludeMediaReplies != excludeRepliesBefore) {
          _mediaTabLoaded = false;
          setState(() {
            _mediaPosts = [];
            _loadingMediaPosts = true;
          });
          _loadMediaPosts();
        }
      }
    } catch (_) {
      // Keep the original user data if full fetch fails.
    }
  }

  /// [_visibleTabs] の件数が現行 TabController と食い違ったら作り直す。
  /// 初期の widget.user に show_media が無く、_fetchFullUser 後に判明して
  /// メディアタブが増減するケースに対応する（#732）。
  void _syncTabController() {
    final desired = _visibleTabs.length;
    if (_tabController.length == desired) return;
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _tabController = TabController(length: desired, vsync: this);
    _tabController.addListener(_onTabChanged);
    if (mounted) setState(() {});
  }

  Future<List<Post>> _fetchUserPosts(
    BackendAdapter adapter, {
    String? maxId,
    bool? onlyMedia,
    bool? excludeReplies,
  }) async {
    // Use dynamic dispatch to call getUserPosts on the concrete adapter.
    // Both MastodonAdapter and MisskeyAdapter define this method.
    final posts =
        await (adapter as dynamic).getUserPosts(
              widget.user.id,
              maxId: maxId,
              onlyMedia: onlyMedia,
              excludeReplies: excludeReplies,
            )
            as List<Post>;
    return ref.read(isCatEnricherProvider).enrichPosts(posts);
  }

  /// メディアタブで返信の添付を除外すべきか (#809)。所有者が Mastodon 4.6 の
  /// `show_media_replies=false` を設定している場合のみ true。未対応サーバー
  /// (null) や true のときは従来どおり返信も含める。
  bool get _excludeMediaReplies => _user.showMediaReplies == false;

  @override
  Widget build(BuildContext context) {
    final user = _user;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            backgroundColor: colorScheme.inversePrimary,
            leading: Padding(
              padding: const EdgeInsets.all(8),
              child: CircleAvatar(
                backgroundColor: Colors.black38,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // ヘッダー画像をタップで全画面表示。alt を説明に載せる (#733)。
                onTap: user.bannerUrl != null
                    ? () => _openImageViewer(
                        user.bannerUrl!,
                        user.bannerDescription,
                      )
                    : null,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (user.bannerUrl != null)
                      Image.network(
                        user.bannerUrl!,
                        fit: BoxFit.cover,
                        semanticLabel: user.bannerDescription,
                      )
                    else
                      Container(color: colorScheme.primaryContainer),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.5),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(child: _buildProfileHeader(context, user)),
          SliverPersistentHeader(
            pinned: true,
            delegate: _TabBarDelegate(
              TabBar(
                controller: _tabController,
                tabs: _visibleTabs
                    .map((t) => Tab(text: _tabLabels[t]))
                    .toList(),
              ),
              colorScheme.surface,
            ),
          ),
          ..._buildTabContent(colorScheme),
        ],
      ),
    );
  }

  List<Widget> _buildTabContent(ColorScheme colorScheme) {
    final tabs = _visibleTabs;
    if (_tabController.index >= tabs.length) {
      return [const SliverFillRemaining(child: SizedBox.shrink())];
    }
    switch (tabs[_tabController.index]) {
      case _ProfileTab.posts:
        return _buildPostsTab(colorScheme);
      case _ProfileTab.media:
        return _buildMediaTab();
      case _ProfileTab.gallery:
        return _buildGalleryTab();
      case _ProfileTab.pages:
        return _buildPagesTab();
    }
  }

  List<Widget> _buildPostsTab(ColorScheme colorScheme) {
    return [
      // show_featured == false のとき固定投稿（フィーチャー）を隠す（#732）。
      if (_pinnedPosts.isNotEmpty && _user.showFeatured != false) ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Icon(
                  Icons.push_pin,
                  size: 14,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  'ピン留め',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => Column(
              children: [
                PostTile(
                  post: _pinnedPosts[index],
                  onPostUpdated: _onPostUpdated,
                ),
                const Divider(height: 1),
              ],
            ),
            childCount: _pinnedPosts.length,
          ),
        ),
        const SliverToBoxAdapter(child: Divider(height: 8, thickness: 4)),
      ],
      if (_loadingPosts)
        const SliverFillRemaining(
          child: Center(child: CircularProgressIndicator()),
        )
      else
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            if (index >= _posts.length) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return Column(
              children: [
                PostTile(post: _posts[index], onPostUpdated: _onPostUpdated),
                const Divider(height: 1),
              ],
            );
          }, childCount: _posts.length + (_loadingMore ? 1 : 0)),
        ),
    ];
  }

  List<Widget> _buildMediaTab() {
    if (_loadingMediaPosts) {
      return [
        const SliverFillRemaining(
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_mediaPosts.isEmpty) {
      return [
        const SliverFillRemaining(
          child: Center(child: Text('メディア付きの投稿はありません')),
        ),
      ];
    }
    return [
      SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          if (index >= _mediaPosts.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return Column(
            children: [
              PostTile(post: _mediaPosts[index], onPostUpdated: _onPostUpdated),
              const Divider(height: 1),
            ],
          );
        }, childCount: _mediaPosts.length + (_loadingMoreMedia ? 1 : 0)),
      ),
    ];
  }

  List<Widget> _buildGalleryTab() {
    if (_loadingGallery) {
      return [
        const SliverFillRemaining(
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_galleryPosts.isEmpty) {
      return [
        const SliverFillRemaining(child: Center(child: Text('ギャラリー投稿はありません'))),
      ];
    }
    final theme = Theme.of(context);
    return [
      SliverPadding(
        padding: const EdgeInsets.all(8),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            if (index >= _galleryPosts.length) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final post = _galleryPosts[index];
            final thumbnail = post.files.isNotEmpty
                ? post.files.first.previewUrl ?? post.files.first.url
                : null;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
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
                                  color:
                                      theme.colorScheme.surfaceContainerHighest,
                                  child: const Center(
                                    child: Icon(Icons.visibility_off),
                                  ),
                                )
                              : Image.network(
                                  thumbnail,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Container(
                                    color: theme
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    child: const Center(
                                      child: Icon(Icons.broken_image),
                                    ),
                                  ),
                                ),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          post.title,
                          style: theme.textTheme.titleMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }, childCount: _galleryPosts.length + (_loadingMoreGallery ? 1 : 0)),
        ),
      ),
    ];
  }

  List<Widget> _buildPagesTab() {
    if (_loadingPages) {
      return [
        const SliverFillRemaining(
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_pages.isEmpty) {
      return [
        const SliverFillRemaining(child: Center(child: Text('ページはありません'))),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.all(8),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            if (index >= _pages.length) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return PageCard(page: _pages[index]);
          }, childCount: _pages.length + (_loadingMorePages ? 1 : 0)),
        ),
      ),
    ];
  }

  /// ミュート中の相手には「ミュート中」バッジをプロフィール本体にも出す。
  /// 期限付きミュート（Mastodon 4.6, #734）は「〇〇まで」を併記する。
  /// 自分のプロフィール・関係性未ロード・非ミュートでは何も出さない。
  /// ブロック中はプロフィール画面へ到達しないため対象外。
  List<Widget> _buildMuteBadge(ThemeData theme) {
    final rel = _relationship;
    if (_isOwnProfile || rel == null || !rel.muting) return const [];
    final label = rel.mutingExpiresAt != null
        ? 'ミュート中（${formatAbsoluteTime(rel.mutingExpiresAt!)}まで）'
        : 'ミュート中';
    return [
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.volume_off,
                size: 16,
                color: theme.colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _buildProfileHeader(BuildContext context, User user) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: user.avatarUrl != null
                    ? () => _openImageViewer(
                        user.avatarUrl!,
                        user.avatarDescription,
                      )
                    : null,
                child: UserAvatar(user: user, size: 72, borderRadius: 8),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: EmojiText(
                            user.displayName ?? user.username,
                            emojis: user.emojis,
                            fallbackHost: user.host,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (user.isBot) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: 'Bot',
                            child: Icon(
                              Icons.smart_toy,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (user.isGroup) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: 'コミュニティ',
                            child: Icon(
                              Icons.groups,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        // サポーターバッジは下のロール Chip 列に移動 (#605)。
                        // 名前横の素アイコンだけでは意味が伝わりにくく、ロール
                        // と並列に Chip 化することで「サポーター」のラベル付き
                        // で示し可読性を上げる。capsicum アイコンは Chip の
                        // avatar に残してブランド一貫性を保つ。
                      ],
                    ),
                    Text(
                      '@${user.username}@${user.host ?? ""}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (user.host != null) _buildServerInfo(user.host!, theme),
                  ],
                ),
              ),
            ],
          ),
          ..._buildMuteBadge(theme),
          if (user.description != null && user.description!.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildBio(user, theme),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              _statItem(context, ref.watch(postLabelProvider), user.postCount),
              // hide_collections == true のときフォロー/フォロワーの
              // カウント・導線を隠す（Mastodon 4.6、#732）。
              if (user.hideCollections != true) ...[
                const SizedBox(width: 24),
                GestureDetector(
                  onTap: () {
                    final adapter =
                        ref.read(currentAdapterProvider)! as FollowSupport;
                    context.push(
                      '/users',
                      extra: {
                        'title': 'フォロー',
                        'fetcher': (String? cursor) => adapter.getFollowing(
                          user.id,
                          query: TimelineQuery(maxId: cursor, limit: 20),
                        ),
                      },
                    );
                  },
                  child: _statItem(context, 'フォロー', user.followingCount),
                ),
                const SizedBox(width: 24),
                GestureDetector(
                  onTap: () {
                    final adapter =
                        ref.read(currentAdapterProvider)! as FollowSupport;
                    context.push(
                      '/users',
                      extra: {
                        'title': 'フォロワー',
                        'fetcher': (String? cursor) => adapter.getFollowers(
                          user.id,
                          query: TimelineQuery(maxId: cursor, limit: 20),
                        ),
                      },
                    );
                  },
                  child: _statItem(context, 'フォロワー', user.followersCount),
                ),
              ],
            ],
          ),
          ..._buildProfileActionRow(context, user),
          if (user.createdAt != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.calendar_month,
                  size: 16,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 4),
                Text(
                  '${user.createdAt!.year}年${user.createdAt!.month}月${user.createdAt!.day}日から利用',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ],
          // サポーターバッジ (#428 B-3 / #605) は装飾のみ・自分のみ可視で、
          // ロール chip 列と統合表示する。状態は SupporterStatus 抽象層
          // (isSupporterProvider) からのみ取得し、他者プロフィールには出さない。
          () {
            final showSupporterChip =
                _isOwnProfile && ref.watch(isSupporterProvider);
            if (user.roles.isEmpty && !showSupporterChip) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  ...user.roles.map((role) {
                    Color? roleColor;
                    if (role.color != null &&
                        role.color!.startsWith('#') &&
                        role.color!.length >= 7) {
                      try {
                        roleColor = Color(
                          0xFF000000 |
                              int.parse(role.color!.substring(1, 7), radix: 16),
                        );
                      } catch (_) {}
                    }
                    // ラベルと境界線で同じ色を使う。サーバー指定色が無いロールは
                    // サポーター chip と同じ primary にフォールバックし、境界線が
                    // 見えなくなる (side: null) のを防ぐ (#605)。
                    final chipColor = roleColor ?? theme.colorScheme.primary;
                    Widget? avatar;
                    if (role.iconUrl != null) {
                      avatar = Image.network(
                        role.iconUrl!,
                        width: 16,
                        height: 16,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      );
                    } else if (role.isAdmin) {
                      final sabacanUrl = ref
                          .watch(sabacanUrlProvider)
                          .valueOrNull;
                      avatar = sabacanUrl != null
                          ? Image.network(
                              sabacanUrl,
                              width: 16,
                              height: 16,
                              errorBuilder: (_, _, _) =>
                                  const Icon(Icons.shield, size: 16),
                            )
                          : const Icon(Icons.shield, size: 16);
                    }
                    return Chip(
                      avatar: avatar,
                      label: Text(
                        role.name,
                        style: TextStyle(fontSize: 12, color: chipColor),
                      ),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(color: chipColor.withValues(alpha: 0.5)),
                    );
                  }),
                  if (showSupporterChip)
                    Chip(
                      avatar: Image.asset(
                        AppConstants.supporterIconAsset,
                        width: 16,
                        height: 16,
                      ),
                      label: Text(
                        'サポーター',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(
                        color: theme.colorScheme.primary.withValues(alpha: 0.5),
                      ),
                    ),
                ],
              ),
            );
          }(),
          if (user.fields.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...user.fields.map(
              (field) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 100,
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              field.name,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (field.verifiedAt != null) ...[
                            const SizedBox(width: 4),
                            Icon(
                              Icons.check_circle,
                              size: 14,
                              color: Colors.green.shade600,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildFieldValue(field, user.emojis, theme),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const Divider(height: 24),
        ],
      ),
    );
  }

  /// プロフィール画面のアクションボタンを Wrap で横並びに配置する。
  /// 自他・能力・関係性で表示するボタンを切り替える:
  /// - 実績 (AchievementSupport がある adapter)
  /// - プロフィールを編集 (自分)
  /// - メッセージを送る (相手・chat 可能)
  /// - フォロー / フォロー解除 (相手・関係性ロード済み)
  /// - PopupMenu (相手・関係性ロード済み: URL コピー / ミュート / ブロック)
  ///
  /// 1 件もない場合は空リストを返し、呼び出し側の SizedBox も挿入されない。
  List<Widget> _buildProfileActionRow(BuildContext context, User user) {
    final adapter = ref.read(currentAdapterProvider);
    final actions = <Widget>[];

    if (adapter is AchievementSupport) {
      actions.add(
        OutlinedButton.icon(
          onPressed: () => context.push(
            '/achievements',
            extra: {
              'userId': user.id,
              'displayName': user.displayName ?? user.username,
            },
          ),
          icon: const Icon(Icons.emoji_events, size: 16),
          label: const Text('実績'),
        ),
      );
    }

    if (_isOwnProfile) {
      actions.add(
        OutlinedButton.icon(
          onPressed: () async {
            final updatedUser = await context.push<User>('/profile/edit');
            if (updatedUser != null && mounted) {
              setState(() => _user = updatedUser);
            }
          },
          icon: const Icon(Icons.edit, size: 16),
          label: const Text('プロフィールを編集'),
        ),
      );
      actions.add(_buildOwnProfileMenu());
    } else {
      if (_canStartChatWith(user)) {
        actions.add(
          OutlinedButton.icon(
            onPressed: () => context.push('/chat/user/${user.id}', extra: user),
            icon: const Icon(Icons.chat_bubble_outline, size: 16),
            label: const Text('メッセージを送る'),
          ),
        );
      }
      if (_relationship != null) {
        actions.addAll(_buildRelationshipButtons(context));
      }
    }

    if (actions.isEmpty) return const [];
    return [
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 4, children: actions),
    ];
  }

  /// 他人のプロフィールでフォロー / メニューボタンを返す。
  /// Wrap 内に並べる前提で、以前の Row(Expanded(...)) ではなく content-sized
  /// なボタンを返す。
  List<Widget> _buildRelationshipButtons(BuildContext context) {
    final rel = _relationship!;
    final adapter = ref.read(currentAdapterProvider)! as FollowSupport;
    return [
      FilledButton.icon(
        onPressed: _relationshipLoading
            ? null
            : () => _performAction(
                () => rel.following
                    ? adapter.unfollowUser(widget.user.id)
                    : adapter.followUser(widget.user.id),
              ),
        icon: Icon(rel.following ? Icons.person_remove : Icons.person_add),
        label: Text(rel.following ? 'フォロー解除' : 'フォロー'),
        style: rel.following
            ? FilledButton.styleFrom(
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
                foregroundColor: Theme.of(context).colorScheme.onSurface,
              )
            : null,
      ),
      PopupMenuButton<String>(
        onSelected: (value) async {
          switch (value) {
            case 'copy_url':
              _copyUrl(context);
            case 'copy_acct':
              _copyAcct(context);
            case 'mention_compose':
              context.push(
                '/compose',
                extra: {'initialText': '@${userAcct(widget.user)} '},
              );
            case 'mute':
              final ok = await _performAction(
                () => adapter.muteUser(widget.user.id),
              );
              if (ok) {
                ref
                    .read(timelineProvider.notifier)
                    .removePostsByUser(widget.user.id);
              }
            case 'mute_duration':
              final ok = await _showMuteDurationPicker(adapter);
              if (ok) {
                ref
                    .read(timelineProvider.notifier)
                    .removePostsByUser(widget.user.id);
              }
            case 'unmute':
              _performAction(() => adapter.unmuteUser(widget.user.id));
            case 'block':
              await _confirmAndBlock(adapter);
            case 'unblock':
              _performAction(() => adapter.unblockUser(widget.user.id));
            case 'view_collections':
              _openCollections(
                inCollections: false,
                ownerView: false,
                title: 'コレクション',
              );
            case 'view_in_collections':
              _openCollections(
                inCollections: true,
                ownerView: false,
                title: '載っているコレクション',
              );
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'mention_compose',
            child: Text('メンションして投稿'),
          ),
          const PopupMenuItem(value: 'copy_acct', child: Text('ユーザー名をコピー')),
          if (widget.user.url != null)
            const PopupMenuItem(value: 'copy_url', child: Text('URL をコピー')),
          if (rel.muting)
            PopupMenuItem(
              value: 'unmute',
              child: Text(
                rel.mutingExpiresAt != null
                    ? 'ミュート解除（${formatAbsoluteTime(rel.mutingExpiresAt!)}まで）'
                    : 'ミュート解除',
              ),
            )
          else ...[
            const PopupMenuItem(value: 'mute', child: Text('ミュート')),
            const PopupMenuItem(
              value: 'mute_duration',
              child: Text('期間を指定してミュート'),
            ),
          ],
          if (rel.blocking)
            const PopupMenuItem(value: 'unblock', child: Text('ブロック解除'))
          else
            const PopupMenuItem(value: 'block', child: Text('ブロック')),
          if (_supportsCollections) ...[
            const PopupMenuItem(
              value: 'view_collections',
              child: Text('コレクション'),
            ),
            const PopupMenuItem(
              value: 'view_in_collections',
              child: Text('載っているコレクション'),
            ),
          ],
        ],
      ),
    ];
  }

  /// 自分のプロフィールにも出す軽量メニュー。メンション / ミュート / ブロックは
  /// 自分には無意味なため、自己適用しうるコピー系のみを並べる。
  /// コピー処理は [_buildRelationshipButtons] の PopupMenu と [_copyAcct] /
  /// [_copyUrl] を共有する。
  Widget _buildOwnProfileMenu() {
    return PopupMenuButton<String>(
      onSelected: (value) {
        switch (value) {
          case 'copy_acct':
            _copyAcct(context);
          case 'copy_url':
            _copyUrl(context);
          case 'my_collections':
            _openCollections(
              inCollections: false,
              ownerView: true,
              title: '自分のコレクション',
            );
          case 'in_collections':
            _openCollections(
              inCollections: true,
              ownerView: false,
              title: '載っているコレクション',
            );
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'copy_acct', child: Text('ユーザー名をコピー')),
        if (widget.user.url != null)
          const PopupMenuItem(value: 'copy_url', child: Text('URL をコピー')),
        if (_supportsCollections) ...[
          const PopupMenuItem(
            value: 'my_collections',
            child: Text('自分のコレクション'),
          ),
          const PopupMenuItem(
            value: 'in_collections',
            child: Text('載っているコレクション'),
          ),
        ],
      ],
    );
  }

  /// Mastodon 4.6 Collections（#722 / #742）の操作を出せるか。
  ///
  /// アダプタ型（CollectionsSupport＝Mastodon）は `CollectionsSupport` を一律
  /// mixin しているため全 Mastodon で true になる。だが Collections API は
  /// Mastodon 4.6.0 追加で、4.5 以前ではメニューを出しても 404 になる（#810）。
  /// そこで**サーバー版が 4.6 以上**であることも要求する。版が未取得（null）の
  /// ときは安全側に倒して出さない（版はログイン / セッション復元時に nodeinfo で
  /// 再取得されるため、恒久的に消えるわけではない）。
  bool get _supportsCollections {
    if (ref.read(currentAdapterProvider) is! CollectionsSupport) return false;
    final version = ref.read(currentAccountProvider)?.softwareVersion;
    if (version == null) return false;
    return ServerVersionChecker.isAtLeast(version, '4.6.0');
  }

  /// アバター/ヘッダー画像をメディアビューアで全画面表示する。alt テキスト
  /// （avatar_description / header_description、#733）を説明キャプションに載せる。
  void _openImageViewer(String url, String? description) {
    context.push(
      '/media',
      extra: {
        'attachments': [
          Attachment(
            id: 'profile-image',
            type: AttachmentType.image,
            url: url,
            description: description,
          ),
        ],
        'initialIndex': 0,
      },
    );
  }

  void _openCollections({
    required bool inCollections,
    required bool ownerView,
    required String title,
  }) {
    context.push(
      '/collections',
      extra: {
        'accountId': widget.user.id,
        'inCollections': inCollections,
        'ownerView': ownerView,
        'title': title,
      },
    );
  }

  void _copyAcct(BuildContext context) {
    Clipboard.setData(ClipboardData(text: '@${userAcct(widget.user)}'));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('ユーザー名をコピーしました')));
    }
  }

  void _copyUrl(BuildContext context) {
    if (widget.user.url == null) return;
    Clipboard.setData(ClipboardData(text: widget.user.url!));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('URL をコピーしました')));
    }
  }

  Future<bool> _showMuteDurationPicker(FollowSupport adapter) async {
    final durations = <(String, Duration)>[
      ('30分', const Duration(minutes: 30)),
      ('1時間', const Duration(hours: 1)),
      ('6時間', const Duration(hours: 6)),
      ('1日', const Duration(days: 1)),
      ('3日', const Duration(days: 3)),
      ('7日', const Duration(days: 7)),
    ];
    final selected = await showModalBottomSheet<Duration>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'ミュート期間',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ...durations.map(
              (entry) => ListTile(
                title: Text(entry.$1),
                onTap: () => Navigator.pop(context, entry.$2),
              ),
            ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) {
      return _performAction(
        () => adapter.muteUser(widget.user.id, duration: selected),
      );
    }
    return false;
  }

  Future<void> _confirmAndBlock(FollowSupport adapter) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ブロック'),
        content: Text('@${widget.user.username} をブロックしますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('ブロック'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final success = await _performAction(
        () => adapter.blockUser(widget.user.id),
      );
      if (!success || !mounted) return;
      ref.read(timelineProvider.notifier).removePostsByUser(widget.user.id);
      await _showReportToDeveloperDialog();
    }
  }

  Future<void> _showReportToDeveloperDialog() async {
    final shouldReport = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('開発者への報告'),
        content: const Text('このユーザーをブロックしました。\nこの問題をアプリ開発者にも報告しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('しない'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('報告する'),
          ),
        ],
      ),
    );
    if (shouldReport == true) {
      launchUrlSafely(
        AppConstants.contactUrl,
        mode: LaunchMode.externalApplication,
      );
    }
  }

  Widget _statItem(BuildContext context, String label, int count) {
    return Column(
      children: [
        Text(
          _formatCount(count),
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  String _formatCount(int count) {
    if (count >= 10000) return '${(count / 1000).toStringAsFixed(1)}K';
    return count.toString();
  }

  Future<void> _navigateToMention(String mention) async {
    final parts = mention.replaceFirst('@', '').split('@');
    if (parts.isEmpty) return;
    final username = parts[0];
    final host = parts.length > 1 ? parts[1] : null;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;
    try {
      final user = await adapter.getUser(username, host);
      if (user != null && mounted) {
        context.push('/profile', extra: user);
      }
    } on Exception catch (e) {
      debugPrint('Failed to look up mention $mention: $e');
    }
  }

  Widget _buildBio(User user, ThemeData theme) {
    _bioRenderer?.dispose();
    final stripped = _stripHtml(user.description!);
    _bioRenderer = ContentRenderer(
      baseStyle: theme.textTheme.bodyMedium ?? const TextStyle(),
      resolveEmoji: (shortcode) {
        final url = user.emojis[shortcode];
        if (url != null) return url;
        if (user.host != null) {
          return 'https://${user.host}/emoji/$shortcode.webp';
        }
        return null;
      },
      resolveUrl: (url) =>
          TcoResolver.isTcoUrl(url) ? TcoResolver.getCached(url) : null,
      onLinkTap: (url) => openFediverseLink(context, ref, url),
      onHashtagTap: (tag) => context.push('/hashtag/$tag'),
      onMentionTap: (mention) => _navigateToMention(mention),
      emojiSize: ref.watch(emojiSizeProvider),
    );
    return RichText(text: _bioRenderer!.renderMfm(stripped));
  }

  Widget _buildFieldValue(
    UserField field,
    Map<String, String> emojis,
    ThemeData theme,
  ) {
    final stripped = _stripHtml(field.value);
    final renderer = ContentRenderer(
      baseStyle: theme.textTheme.bodyMedium ?? const TextStyle(),
      resolveEmoji: (shortcode) {
        final url = emojis[shortcode];
        if (url != null) return url;
        final host = widget.user.host;
        if (host != null) {
          return 'https://$host/emoji/$shortcode.webp';
        }
        return null;
      },
      resolveUrl: (url) =>
          TcoResolver.isTcoUrl(url) ? TcoResolver.getCached(url) : null,
      resolveDisplayUrl: _tryResolveAcct,
      onLinkTap: (url) => openFediverseLink(context, ref, url),
      onHashtagTap: (tag) => context.push('/hashtag/$tag'),
      emojiSize: ref.watch(emojiSizeProvider),
    );
    return RichText(text: renderer.renderMfm(stripped));
  }

  static final _profileUrlPattern = RegExp(
    r'^https?://([^/]+)/@([a-zA-Z0-9_]+)/?$',
  );

  String? _tryResolveAcct(String url) {
    final match = _profileUrlPattern.firstMatch(url);
    if (match == null) return null;
    final host = match.group(1)!;
    final username = match.group(2)!;
    return '@$username@$host';
  }

  String _stripHtml(String html) => stripHtml(html);

  Widget _buildServerInfo(String host, ThemeData theme) {
    final themeColors = ref.watch(hostThemeColorProvider);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: ServerBadge.fromHost(host, themeColors: themeColors),
    );
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  final Color backgroundColor;

  _TabBarDelegate(this.tabBar, this.backgroundColor);

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return ColoredBox(color: backgroundColor, child: tabBar);
  }

  @override
  bool shouldRebuild(_TabBarDelegate oldDelegate) => false;
}

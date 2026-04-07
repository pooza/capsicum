import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../constants.dart';
import '../../url_helper.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../provider/timeline_provider.dart';
import '../../service/tco_resolver.dart';
import '../widget/server_badge.dart';
import '../widget/content_parser.dart';
import '../widget/emoji_text.dart';
import '../widget/post_tile.dart';
import '../widget/user_avatar.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  final User user;

  const ProfileScreen({super.key, required this.user});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
    with SingleTickerProviderStateMixin {
  final _scrollController = ScrollController();
  late final TabController _tabController;
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

  bool get _hasGalleryTab => ref.read(currentAdapterProvider) is GallerySupport;

  UserRelationship? _relationship;
  bool _relationshipLoading = false;

  bool get _isOwnProfile {
    final current = ref.read(currentAccountProvider);
    return current != null && current.user.id == widget.user.id;
  }

  static final _tcoPattern = RegExp(r'https?://t\.co/\S+');
  ContentRenderer? _bioRenderer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _hasGalleryTab ? 3 : 2, vsync: this);
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
    if (_tabController.index == 1 && !_mediaTabLoaded) {
      _loadMediaPosts();
    }
    if (_tabController.index == 2 && !_galleryTabLoaded) {
      _loadGalleryPosts();
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
      if (_tabController.index == 0) {
        _loadMorePosts();
      } else if (_tabController.index == 1) {
        _loadMoreMediaPosts();
      } else if (_tabController.index == 2) {
        _loadMoreGalleryPosts();
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
      final posts = await _fetchUserPosts(adapter, onlyMedia: true);
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
      final fullUser = await adapter.getUserById(widget.user.id);
      if (mounted) setState(() => _user = fullUser);
    } catch (_) {
      // Keep the original user data if full fetch fails.
    }
  }

  Future<List<Post>> _fetchUserPosts(
    BackendAdapter adapter, {
    String? maxId,
    bool? onlyMedia,
  }) async {
    // Use dynamic dispatch to call getUserPosts on the concrete adapter.
    // Both MastodonAdapter and MisskeyAdapter define this method.
    return await (adapter as dynamic).getUserPosts(
          widget.user.id,
          maxId: maxId,
          onlyMedia: onlyMedia,
        )
        as List<Post>;
  }

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
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (user.bannerUrl != null)
                    Image.network(user.bannerUrl!, fit: BoxFit.cover)
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
          SliverToBoxAdapter(child: _buildProfileHeader(context, user)),
          SliverPersistentHeader(
            pinned: true,
            delegate: _TabBarDelegate(
              TabBar(
                controller: _tabController,
                tabs: [
                  const Tab(text: '投稿'),
                  const Tab(text: 'メディア'),
                  if (_hasGalleryTab) const Tab(text: 'ギャラリー'),
                ],
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
    if (_tabController.index == 0) {
      return _buildPostsTab(colorScheme);
    } else if (_tabController.index == 1) {
      return _buildMediaTab();
    } else {
      return _buildGalleryTab();
    }
  }

  List<Widget> _buildPostsTab(ColorScheme colorScheme) {
    return [
      if (_pinnedPosts.isNotEmpty) ...[
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

  Widget _buildProfileHeader(BuildContext context, User user) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              UserAvatar(user: user, size: 72, borderRadius: 8),
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
          if (user.description != null && user.description!.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildBio(user, theme),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              _statItem(context, ref.watch(postLabelProvider), user.postCount),
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
          ),
          if (ref.read(currentAdapterProvider) is AchievementSupport)
            OutlinedButton.icon(
              onPressed: () => context.push('/achievements', extra: {
                'userId': user.id,
                'displayName': user.displayName ?? user.username,
              }),
              icon: const Icon(Icons.emoji_events, size: 16),
              label: const Text('実績'),
            ),
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
          if (_isOwnProfile) ...[
            const SizedBox(height: 12),
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
          ],
          if (!_isOwnProfile && _relationship != null) ...[
            const SizedBox(height: 12),
            _buildActionButtons(context),
          ],
          if (user.roles.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: user.roles.map((role) {
                Color? chipColor;
                if (role.color != null &&
                    role.color!.startsWith('#') &&
                    role.color!.length >= 7) {
                  try {
                    chipColor = Color(
                      0xFF000000 |
                          int.parse(role.color!.substring(1, 7), radix: 16),
                    );
                  } catch (_) {}
                }
                Widget? avatar;
                if (role.iconUrl != null) {
                  avatar = Image.network(
                    role.iconUrl!,
                    width: 16,
                    height: 16,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  );
                } else if (role.isAdmin) {
                  final sabacanUrl = ref.watch(sabacanUrlProvider).valueOrNull;
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
                  side: chipColor != null
                      ? BorderSide(color: chipColor.withValues(alpha: 0.5))
                      : null,
                );
              }).toList(),
            ),
          ],
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

  Widget _buildActionButtons(BuildContext context) {
    final rel = _relationship!;
    final adapter = ref.read(currentAdapterProvider)! as FollowSupport;

    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
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
        ),
        const SizedBox(width: 8),
        PopupMenuButton<String>(
          onSelected: (value) async {
            switch (value) {
              case 'copy_url':
                if (widget.user.url != null) {
                  Clipboard.setData(ClipboardData(text: widget.user.url!));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('URL をコピーしました')),
                    );
                  }
                }
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
            }
          },
          itemBuilder: (_) => [
            if (widget.user.url != null)
              const PopupMenuItem(value: 'copy_url', child: Text('URL をコピー')),
            if (rel.muting)
              const PopupMenuItem(value: 'unmute', child: Text('ミュート解除'))
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
          ],
        ),
      ],
    );
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
      onLinkTap: (url) {
        final uri = Uri.tryParse(url);
        if (uri != null) launchUrlSafely(uri);
      },
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
      onLinkTap: (url) {
        final uri = Uri.tryParse(url);
        if (uri != null) launchUrlSafely(uri);
      },
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

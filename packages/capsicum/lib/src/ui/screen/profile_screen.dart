import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/server_config_provider.dart';
import '../widget/emoji_text.dart';
import '../widget/post_tile.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  final User user;

  const ProfileScreen({super.key, required this.user});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _scrollController = ScrollController();
  late User _user = widget.user;
  List<Post> _pinnedPosts = [];
  List<Post> _posts = [];
  bool _loadingPosts = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  UserRelationship? _relationship;
  bool _relationshipLoading = false;

  bool get _isOwnProfile {
    final current = ref.read(currentAccountProvider);
    return current != null && current.user.id == widget.user.id;
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _fetchFullUser();
    _loadPinnedPosts();
    _loadPosts();
    _loadRelationship();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMorePosts();
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

  Future<void> _loadPosts() async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    try {
      final posts = await _fetchUserPosts(adapter);
      if (mounted) {
        setState(() {
          _posts = posts;
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

  Future<void> _performAction(Future<void> Function() action) async {
    if (_relationshipLoading) return;
    setState(() => _relationshipLoading = true);
    try {
      await action();
      await _loadRelationship();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作に失敗しました')));
      }
      debugPrint('User action error: $e');
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
  }) async {
    // Use dynamic dispatch to call getUserPosts on the concrete adapter.
    // Both MastodonAdapter and MisskeyAdapter define this method.
    return await (adapter as dynamic).getUserPosts(widget.user.id, maxId: maxId)
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
          if (_pinnedPosts.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
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
                    PostTile(post: _pinnedPosts[index]),
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
                    PostTile(post: _posts[index]),
                    const Divider(height: 1),
                  ],
                );
              }, childCount: _posts.length + (_loadingMore ? 1 : 0)),
            ),
        ],
      ),
    );
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
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: user.avatarUrl != null
                    ? Image.network(
                        user.avatarUrl!,
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                      )
                    : Container(
                        width: 72,
                        height: 72,
                        color: theme.colorScheme.primaryContainer,
                        alignment: Alignment.center,
                        child: Text(
                          user.username[0].toUpperCase(),
                          style: const TextStyle(fontSize: 28),
                        ),
                      ),
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
                  ],
                ),
              ),
            ],
          ),
          if (user.description != null && user.description!.isNotEmpty) ...[
            const SizedBox(height: 12),
            EmojiText(
              _stripHtml(user.description!),
              emojis: user.emojis,
              style: theme.textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              _statItem(context, ref.watch(postLabelProvider), user.postCount),
              const SizedBox(width: 24),
              GestureDetector(
                onTap: () => context.push('/following', extra: user),
                child: _statItem(context, 'フォロー', user.followingCount),
              ),
              const SizedBox(width: 24),
              GestureDetector(
                onTap: () => context.push('/followers', extra: user),
                child: _statItem(context, 'フォロワー', user.followersCount),
              ),
            ],
          ),
          if (!_isOwnProfile && _relationship != null) ...[
            const SizedBox(height: 12),
            _buildActionButtons(context),
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
                      child: Text(
                        field.name,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: EmojiText(
                        _stripHtml(field.value),
                        emojis: user.emojis,
                        style: theme.textTheme.bodyMedium,
                      ),
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
          onSelected: (value) {
            switch (value) {
              case 'mute':
                _performAction(() => adapter.muteUser(widget.user.id));
              case 'mute_duration':
                _showMuteDurationPicker(adapter);
              case 'unmute':
                _performAction(() => adapter.unmuteUser(widget.user.id));
              case 'block':
                _confirmAndBlock(adapter);
              case 'unblock':
                _performAction(() => adapter.unblockUser(widget.user.id));
            }
          },
          itemBuilder: (_) => [
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

  Future<void> _showMuteDurationPicker(FollowSupport adapter) async {
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
      _performAction(
        () => adapter.muteUser(widget.user.id, duration: selected),
      );
    }
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
      _performAction(() => adapter.blockUser(widget.user.id));
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

  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</p>\s*<p>'), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");
  }
}

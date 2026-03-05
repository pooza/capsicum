import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
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
  List<Post> _posts = [];
  bool _loadingPosts = true;
  bool _loadingMore = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _fetchFullUser();
    _loadPosts();
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
    return await (adapter as dynamic).getUserPosts(
      widget.user.id,
      maxId: maxId,
    ) as List<Post>;
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
          if (_loadingPosts)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
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
                },
                childCount: _posts.length + (_loadingMore ? 1 : 0),
              ),
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
                        child: Text(user.username[0].toUpperCase(),
                            style: const TextStyle(fontSize: 28)),
                      ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    EmojiText(
                      user.displayName ?? user.username,
                      emojis: user.emojis,
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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
              _statItem(context, '投稿', user.postCount),
              const SizedBox(width: 24),
              _statItem(context, 'フォロー', user.followingCount),
              const SizedBox(width: 24),
              _statItem(context, 'フォロワー', user.followersCount),
            ],
          ),
          if (user.fields.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...user.fields.map((field) => Padding(
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
                )),
          ],
          const Divider(height: 24),
        ],
      ),
    );
  }

  Widget _statItem(BuildContext context, String label, int count) {
    return Column(
      children: [
        Text(
          _formatCount(count),
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.bold),
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

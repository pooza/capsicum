import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../widget/emoji_text.dart';
import '../widget/user_avatar.dart';

enum UserListType { followers, following }

class UserListScreen extends ConsumerStatefulWidget {
  final User user;
  final UserListType type;

  const UserListScreen({super.key, required this.user, required this.type});

  @override
  ConsumerState<UserListScreen> createState() => _UserListScreenState();
}

class _UserListScreenState extends ConsumerState<UserListScreen> {
  static const _pageSize = 20;
  final _scrollController = ScrollController();
  List<User> _users = [];
  String? _nextCursor;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadInitial() async {
    final adapter = ref.read(currentAdapterProvider)! as FollowSupport;
    try {
      final result = await _fetch(adapter, null);
      if (!mounted) return;
      setState(() {
        _users = result.users;
        _nextCursor = result.nextCursor;
        _loading = false;
        _hasMore =
            result.users.length >= _pageSize && result.nextCursor != null;
      });
    } catch (e) {
      debugPrint('UserListScreen load error: $e');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _users.isEmpty) return;
    setState(() => _loadingMore = true);
    final adapter = ref.read(currentAdapterProvider)! as FollowSupport;
    try {
      final result = await _fetch(adapter, _nextCursor);
      if (!mounted) return;
      setState(() {
        _users = [..._users, ...result.users];
        _nextCursor = result.nextCursor;
        _loadingMore = false;
        _hasMore =
            result.users.length >= _pageSize && result.nextCursor != null;
      });
    } catch (e) {
      debugPrint('UserListScreen loadMore error: $e');
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  Future<({List<User> users, String? nextCursor})> _fetch(
    FollowSupport adapter,
    String? cursor,
  ) {
    final query = TimelineQuery(maxId: cursor, limit: _pageSize);
    return widget.type == UserListType.followers
        ? adapter.getFollowers(widget.user.id, query: query)
        : adapter.getFollowing(widget.user.id, query: query);
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.type == UserListType.followers ? 'フォロワー' : 'フォロー';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _users.isEmpty
          ? Center(child: Text('$titleはいません'))
          : RefreshIndicator(
              onRefresh: () async {
                setState(() => _loading = true);
                await _loadInitial();
              },
              child: ListView.separated(
                controller: _scrollController,
                itemCount: _users.length + (_loadingMore ? 1 : 0),
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  if (index >= _users.length) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final user = _users[index];
                  return ListTile(
                    onTap: () => context.push('/profile', extra: user),
                    leading: UserAvatar(user: user, size: 40),
                    title: EmojiText(
                      user.displayName ?? user.username,
                      emojis: user.emojis,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '@${user.username}@${user.host}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
            ),
    );
  }
}

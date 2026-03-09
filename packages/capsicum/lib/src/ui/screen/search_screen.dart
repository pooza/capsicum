import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/server_config_provider.dart';
import '../widget/emoji_text.dart';
import '../widget/post_tile.dart';

enum _QueryType { account, hashtag, url, fulltext }

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  SearchResults? _results;
  _QueryType? _queryType;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  _QueryType _detectQueryType(String query) {
    if (query.startsWith('@')) return _QueryType.account;
    if (query.startsWith('#')) return _QueryType.hashtag;
    final uri = Uri.tryParse(query);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
      return _QueryType.url;
    }
    return _QueryType.fulltext;
  }

  Future<void> _search() async {
    final rawQuery = _controller.text.trim();
    if (rawQuery.isEmpty) return;

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! SearchSupport) return;

    final queryType = _detectQueryType(rawQuery);

    // Strip leading @ or # for the actual query.
    final query = switch (queryType) {
      _QueryType.account => rawQuery.substring(1),
      _QueryType.hashtag => rawQuery.substring(1),
      _ => rawQuery,
    };

    if (query.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
      _queryType = queryType;
    });

    try {
      final results = await (adapter as SearchSupport).search(
        queryType == _QueryType.account || queryType == _QueryType.hashtag
            ? query
            : rawQuery,
      );
      if (mounted) setState(() => _results = results);
    } catch (e) {
      debugPrint('Search error: $e');
      if (mounted) setState(() => _error = '検索に失敗しました');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: '検索...',
            border: InputBorder.none,
          ),
          onSubmitted: (_) => _search(),
        ),
        actions: [
          IconButton(
            onPressed: _loading ? null : _search,
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('検索に失敗しました\n$_error', textAlign: TextAlign.center),
        ),
      );
    }
    if (_results == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                '@ユーザー名  アカウントを検索\n'
                '#タグ名  ハッシュタグを検索\n'
                'URL  リモートの${ref.watch(postLabelProvider)}やアカウントを取得\n'
                'キーワード  全文検索',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, height: 1.8),
              ),
            ],
          ),
        ),
      );
    }

    final results = _results!;

    switch (_queryType!) {
      case _QueryType.account:
        return _buildUserList(results.users);
      case _QueryType.hashtag:
        return _buildHashtagList(results.hashtags);
      case _QueryType.url:
        return _buildResolvedResults(results);
      case _QueryType.fulltext:
        return _buildFullResults(results);
    }
  }

  Widget _buildFullResults(SearchResults results) {
    final hasUsers = results.users.isNotEmpty;
    final hasHashtags = results.hashtags.isNotEmpty;
    final hasPosts = results.posts.isNotEmpty;

    if (!hasUsers && !hasHashtags && !hasPosts) {
      return const Center(
        child: Text(
          'このサーバーは全文検索に対応していないか、\n結果が見つかりませんでした',
          textAlign: TextAlign.center,
        ),
      );
    }

    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          TabBar(
            tabs: [
              const Tab(text: 'アカウント'),
              const Tab(text: 'ハッシュタグ'),
              Tab(text: ref.watch(postLabelProvider)),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildUserList(results.users),
                _buildHashtagList(results.hashtags),
                _buildPostList(results.posts),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResolvedResults(SearchResults results) {
    if (results.posts.isNotEmpty) {
      return _buildPostList(results.posts);
    }
    if (results.users.isNotEmpty) {
      return _buildUserList(results.users);
    }
    return const Center(child: Text('URLを解決できませんでした'));
  }

  Widget _buildUserList(List<User> users) {
    if (users.isEmpty) {
      return const Center(child: Text('アカウントが見つかりませんでした'));
    }
    return ListView.separated(
      itemCount: users.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final user = users[index];
        return ListTile(
          onTap: () => context.push('/profile', extra: user),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: user.avatarUrl != null
                ? Image.network(
                    user.avatarUrl!,
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                  )
                : Container(
                    width: 40,
                    height: 40,
                    color: Theme.of(context).colorScheme.primaryContainer,
                    alignment: Alignment.center,
                    child: Text(user.username[0].toUpperCase()),
                  ),
          ),
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
    );
  }

  Widget _buildHashtagList(List<String> hashtags) {
    if (hashtags.isEmpty) {
      return const Center(child: Text('ハッシュタグが見つかりませんでした'));
    }
    return ListView.separated(
      itemCount: hashtags.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final tag = hashtags[index];
        return ListTile(
          leading: const Icon(Icons.tag),
          title: Text('#$tag'),
          onTap: () => context.push('/hashtag/$tag'),
        );
      },
    );
  }

  Widget _buildPostList(List<Post> posts) {
    if (posts.isEmpty) {
      return Center(child: Text('${ref.watch(postLabelProvider)}が見つかりませんでした'));
    }
    return ListView.separated(
      itemCount: posts.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) => PostTile(post: posts[index]),
    );
  }
}

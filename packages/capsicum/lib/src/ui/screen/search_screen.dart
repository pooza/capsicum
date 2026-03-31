import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';

import '../../constants.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/server_config_provider.dart';
import '../widget/emoji_text.dart';
import '../widget/post_tile.dart';
import '../widget/user_avatar.dart';

enum _QueryType { account, hashtag, url, fulltext }

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  late final TabController _tabController;
  SearchResults? _results;
  _QueryType? _queryType;
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>> _notestockResults = [];
  bool _notestockLoading = false;
  String? _notestockNextUrl;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    _tabController.dispose();
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
      _notestockResults = [];
      _notestockLoading = queryType == _QueryType.fulltext;
    });

    try {
      final searchFuture = (adapter as SearchSupport).search(
        queryType == _QueryType.account || queryType == _QueryType.hashtag
            ? query
            : rawQuery,
      );

      // 全文検索時は notestock も並行して呼び出す
      if (queryType == _QueryType.fulltext) {
        _searchNotestock(rawQuery);
      }

      final results = await searchFuture;
      if (mounted) setState(() => _results = results);
    } catch (e) {
      debugPrint('Search error: $e');
      if (mounted) setState(() => _error = '検索に失敗しました');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _searchNotestock(String query, {String? nextUrl}) async {
    final account = ref.read(currentAccountProvider);
    if (account == null) return;
    final acct = '${account.key.username}@${account.key.host}';
    try {
      final dio = Dio();
      final Response<dynamic> response;
      if (nextUrl != null) {
        response = await dio.get(nextUrl);
      } else {
        response = await dio.get(
          '${AppConstants.notestockBaseUrl}/api/v1/search.json',
          queryParameters: {'acct': acct, 'q': query},
        );
      }
      final data = response.data as Map<String, dynamic>;
      final statuses = (data['statuses'] as List<dynamic>?)
              ?.cast<Map<String, dynamic>>() ??
          [];
      final linkHeader = response.headers.value('link');
      String? next;
      if (linkHeader != null) {
        final match = RegExp(r'<([^>]+)>;\s*rel="next"').firstMatch(linkHeader);
        next = match?.group(1);
      }
      if (mounted) {
        setState(() {
          if (nextUrl != null) {
            _notestockResults = [..._notestockResults, ...statuses];
          } else {
            _notestockResults = statuses;
          }
          _notestockNextUrl = next;
          _notestockLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Notestock search error: $e');
      if (mounted) setState(() => _notestockLoading = false);
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
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                '外部の検索サービス',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('notestock'),
                    onPressed: () => launchUrl(
                      AppConstants.notestockUrl,
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Fediver'),
                    onPressed: () => launchUrl(
                      AppConstants.fediverUrl,
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                ],
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
    final hasNotestock = _notestockResults.isNotEmpty || _notestockLoading;

    if (!hasUsers && !hasHashtags && !hasPosts && !hasNotestock) {
      return const Center(
        child: Text(
          'このサーバーは全文検索に対応していないか、\n結果が見つかりませんでした',
          textAlign: TextAlign.center,
        ),
      );
    }

    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: [
              const Tab(text: 'アカウント'),
              const Tab(text: 'ハッシュタグ'),
              Tab(text: ref.watch(postLabelProvider)),
              const Tab(text: 'notestock'),
            ],
          ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildUserList(results.users),
              _buildHashtagList(results.hashtags),
              _buildPostList(results.posts),
              _buildNotestockList(),
            ],
          ),
        ),
      ],
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
          leading: UserAvatar(user: user, size: 40),
          title: EmojiText(
            user.displayName ?? user.username,
            emojis: user.emojis,
            fallbackHost: user.host,
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

  Widget _buildNotestockList() {
    if (_notestockLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_notestockResults.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'notestock に結果がないか、検索が有効になっていません',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse('${AppConstants.notestockBaseUrl}/setting/index.html'),
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text('notestock の設定を開く'),
              ),
            ],
          ),
        ),
      );
    }
    final hasMore = _notestockNextUrl != null;
    final itemCount = _notestockResults.length + (hasMore ? 1 : 0);
    return ListView.separated(
      itemCount: itemCount,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == _notestockResults.length) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _notestockLoading
                  ? const CircularProgressIndicator()
                  : TextButton(
                      onPressed: () {
                        setState(() => _notestockLoading = true);
                        _searchNotestock('', nextUrl: _notestockNextUrl);
                      },
                      child: const Text('もっと読む'),
                    ),
            ),
          );
        }

          final status = _notestockResults[index];
        final content = status['content'] as String? ?? '';
        final url = status['url'] as String? ?? '';
        final published = status['published'] as String?;
        final date = published != null ? DateTime.tryParse(published) : null;

        // HTML タグを簡易除去して表示
        final plainText = content
            .replaceAll(RegExp(r'<br\s*/?>'), '\n')
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"')
            .replaceAll('&#39;', "'")
            .replaceAll('&nbsp;', ' ')
            .trim();

        return ListTile(
          title: Text(
            plainText,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: date != null
              ? Text(
                  '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} '
                  '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}',
                )
              : null,
          onTap: url.isNotEmpty ? () => _resolveAndOpen(url) : null,
        );
      },
    );
  }

  Future<void> _resolveAndOpen(String url) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! SearchSupport) {
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      return;
    }
    try {
      final results = await (adapter as SearchSupport).search(url);
      if (!mounted) return;
      if (results.posts.isNotEmpty) {
        context.push('/post', extra: results.posts.first);
        return;
      }
    } catch (_) {}
    if (mounted) {
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
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

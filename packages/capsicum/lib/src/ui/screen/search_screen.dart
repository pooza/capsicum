import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../url_helper.dart';
import '../../util/exception_scrub.dart';
import '../../util/user_acct.dart';
import '../util/deck_navigation.dart';
import '../util/fediverse_link.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/emoji_text.dart';
import '../widget/post_tile.dart';
import '../widget/user_avatar.dart';

enum _QueryType { account, hashtag, url, fulltext }

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.embedded = false});

  /// デッキのカラムとして出すか (#1173・`docs/deck-ui-plan.md` 決定済み事項 7-3)。
  ///
  /// カラムの見出しは [DeckColumnView] が出すので `Scaffold` / `AppBar` を持たない。
  /// ⚠ **入力欄は chrome ではなく検索の本体**なので、カラムでも残す。
  final bool embedded;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  late final TabController _tabController;
  SearchResults? _results;
  _QueryType? _queryType;
  bool _serverLoading = false;
  String? _error;
  List<Map<String, dynamic>> _notestockResults = [];
  bool _notestockLoading = false;
  String? _notestockNextUrl;

  // サーバー検索の続き (#1202)。
  //
  // ⚠ **検索のたびに世代を進める。**続きを待っている間に別の語で検索し直すと、
  // 古い語の続きが新しい結果の末尾に混ざる。
  int _searchGeneration = 0;
  SearchPagingSupport? _pagingAdapter;
  String _serverQuery = '';

  /// 種別ごとの、サーバーへ送る次の offset。
  ///
  /// ⚠ **表示中の件数から出さない。**重複を落としているので、表示件数で送ると
  /// 落としたぶんだけ同じ行を読み直す。
  final Map<SearchKind, int> _offsets = {};
  final Set<SearchKind> _exhausted = {};
  final Set<SearchKind> _moreLoading = {};

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

    final generation = ++_searchGeneration;
    setState(() {
      _error = null;
      _queryType = queryType;
      _results = SearchResults(users: [], posts: [], hashtags: []);
      _notestockResults = [];
      _notestockLoading = queryType == _QueryType.fulltext;
      _serverLoading = true;
      _pagingAdapter = null;
      _offsets.clear();
      _exhausted.clear();
      _moreLoading.clear();
    });

    // サーバー検索を非同期で開始（レスポンスを待たずに結果UIへ遷移）
    _searchServer(
      adapter as SearchSupport,
      queryType,
      query,
      rawQuery,
      generation,
    );

    // 全文検索時は notestock も並行して呼び出す
    if (queryType == _QueryType.fulltext) {
      _searchNotestock(rawQuery);
    }
  }

  Future<void> _searchServer(
    SearchSupport adapter,
    _QueryType queryType,
    String query,
    String rawQuery,
    int generation,
  ) async {
    final serverQuery =
        queryType == _QueryType.account || queryType == _QueryType.hashtag
        ? query
        : rawQuery;
    try {
      final results = await adapter.search(serverQuery);
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _results = results;
        // ⚠ **URL の解決には続きが無い**（1 件を引く操作）ので口を出さない。
        if (adapter is SearchPagingSupport && queryType != _QueryType.url) {
          final paging = adapter as SearchPagingSupport;
          _pagingAdapter = paging;
          _serverQuery = serverQuery;
          _notePage(SearchKind.users, results.users.length, paging);
          _notePage(SearchKind.posts, results.posts.length, paging);
          _notePage(SearchKind.hashtags, results.hashtags.length, paging);
        }
      });
    } catch (e) {
      debugLogException('Search error', e);
      if (mounted && generation == _searchGeneration) {
        setState(() => _error = '検索に失敗しました');
      }
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => _serverLoading = false);
      }
    }
  }

  /// 1 ページ読んだ結果を、次の offset と終端の判定へ反映する。
  ///
  /// ⚠ **サーバーは総数を返さない**ので、1 ページに満たなければ終端とみなす。
  ///
  /// ⚠⚠ **投稿だけは、空のページが返るまで終端にしない**（リリース前レビュー・
  /// 2026-10-10）。Mastodon は 1 ページぶん取ったあとに、ブロック / ミュート等に
  /// 当たる投稿を落として返すので、**続きがあっても 1 ページに満たないことがある**
  /// （19 件で返ると、続きを読む口が消えていた）。⚠ 代わりに、結果が少ない回は
  /// 口が 1 回残る（押すと空が返って消える）。
  ///
  /// ⚠ 同じ理由で、**投稿の offset は返った件数ではなく 1 ページぶん進める**
  /// （PR #1256 の Codex P2）。サーバーの offset は落とす前の並びに掛かるので、
  /// 返った件数で進めると、次のページが前のページの末尾と重なる。
  /// ⚠ 1 ページが丸ごと落とされた回（全件がブロック / ミュートに当たる）は、
  /// 本当の終端と見分けられないので、終端として扱う。
  void _notePage(SearchKind kind, int fetched, SearchPagingSupport paging) {
    final isPosts = kind == SearchKind.posts;
    _offsets[kind] =
        (_offsets[kind] ?? 0) + (isPosts ? paging.searchPageSize : fetched);
    final atEnd = isPosts ? fetched == 0 : fetched < paging.searchPageSize;
    if (atEnd) _exhausted.add(kind);
  }

  bool _hasMore(SearchKind kind) =>
      _pagingAdapter != null && !_exhausted.contains(kind);

  Future<void> _loadMore(SearchKind kind) async {
    final paging = _pagingAdapter;
    final current = _results;
    if (paging == null || current == null || _moreLoading.contains(kind)) {
      return;
    }
    final generation = _searchGeneration;
    setState(() => _moreLoading.add(kind));
    try {
      final more = await paging.searchMore(
        _serverQuery,
        kind,
        offset: _offsets[kind] ?? 0,
      );
      if (!mounted || generation != _searchGeneration) return;
      final base = _results ?? current;
      final userIds = {for (final u in base.users) u.id};
      final postIds = {for (final p in base.posts) p.id};
      final tags = base.hashtags.toSet();
      setState(() {
        _notePage(kind, switch (kind) {
          SearchKind.users => more.users.length,
          SearchKind.posts => more.posts.length,
          SearchKind.hashtags => more.hashtags.length,
        }, paging);
        _results = SearchResults(
          users: [...base.users, ...more.users.where((u) => userIds.add(u.id))],
          posts: [...base.posts, ...more.posts.where((p) => postIds.add(p.id))],
          hashtags: [...base.hashtags, ...more.hashtags.where(tags.add)],
          postSearchUnavailable: base.postSearchUnavailable,
        );
      });
    } catch (e) {
      debugLogException('Search more error', e);
      // ⚠ **終端にしない。**失敗で口を消すと、押し直す手段が無くなる。
      if (mounted && generation == _searchGeneration) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('続きを読み込めませんでした')));
      }
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => _moreLoading.remove(kind));
      }
    }
  }

  /// 一覧の末尾に置く「もっと読む」。
  Widget _moreFooter(SearchKind kind) => Center(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: _moreLoading.contains(kind)
          ? const CircularProgressIndicator()
          : TextButton(
              onPressed: () => _loadMore(kind),
              child: const Text('もっと読む'),
            ),
    ),
  );

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
      final statuses =
          (data['statuses'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
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
      debugLogException('Notestock search error', e);
      if (mounted) setState(() => _notestockLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: _controller,
      // ⚠⚠ **カラムでは autofocus しない** (#1173)。検索カラムは列に永続化される
      // ので、アプリを起こし直すたびにソフトキーボードが立ち上がってしまう。
      // 全画面の検索は開いた瞬間に打ち始めるものなので従来どおり。
      autofocus: !widget.embedded,
      textInputAction: TextInputAction.search,
      decoration: const InputDecoration(
        hintText: '検索...',
        border: InputBorder.none,
      ),
      onSubmitted: (_) => _search(),
    );
    final submit = IconButton(
      onPressed: _serverLoading ? null : _search,
      icon: const Icon(Icons.search),
    );

    if (widget.embedded) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: [
                Expanded(child: field),
                submit,
              ],
            ),
          ),
          const Divider(height: 1),
          // ⚠ 下端の inset はデッキ画面がまとめて吸う（`BottomSafeArea` を
          // ここで重ねると簡易投稿バーの上に余白が入る）。
          Expanded(child: _buildBody()),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: field,
        actions: [submit],
      ),
      body: BottomSafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_error != null && !_serverLoading) {
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
                    onPressed: () => launchUrlSafely(
                      AppConstants.notestockUrl,
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

    if (_serverLoading) {
      switch (_queryType!) {
        case _QueryType.fulltext:
          return _buildFullResults(results);
        case _QueryType.account:
        case _QueryType.hashtag:
        case _QueryType.url:
          return const Center(child: CircularProgressIndicator());
      }
    }

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

    // ⚠ **本文検索が使えないサーバーでは、この早期 return に入らせない
    // (#1041)。**入るとタブごと消えて「本文検索に対応していない」旨を
    // 出す場所が無くなり、notestock タブにも辿り着けなくなる。
    if (!_serverLoading &&
        !results.postSearchUnavailable &&
        !hasUsers &&
        !hasHashtags &&
        !hasPosts &&
        !hasNotestock) {
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
              _serverLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _buildUserList(results.users),
              _serverLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _buildHashtagList(results.hashtags),
              _serverLoading
                  ? const Center(child: CircularProgressIndicator())
                  // ⚠ **「0 件」と「引けない」を区別する (#1041)。**サーバーが
                  // 全文検索バックエンドを持たないと `notes/search` は
                  // `UNAVAILABLE` を返す。空リストのまま出すと「その語の投稿は
                  // 無い」に見え、実際より悪い誤解を与える。
                  : results.postSearchUnavailable
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'このサーバーは本文検索に対応していません。\n'
                          'アカウント・ハッシュタグの検索と、\n'
                          '下の notestock タブは利用できます。',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : _buildPostList(results.posts),
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
    final hasMore = _hasMore(SearchKind.users);
    return ListView.separated(
      itemCount: users.length + (hasMore ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == users.length) return _moreFooter(SearchKind.users);
        final user = users[index];
        return ListTile(
          onTap: () => openProfile(context, user),
          leading: UserAvatar(user: user, size: 40),
          title: EmojiText(
            user.displayName ?? user.username,
            emojis: user.emojis,
            fallbackHost: user.host,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '@${userAcct(user)}',
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
    final hasMore = _hasMore(SearchKind.hashtags);
    return ListView.separated(
      itemCount: hashtags.length + (hasMore ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == hashtags.length) return _moreFooter(SearchKind.hashtags);
        final tag = hashtags[index];
        return ListTile(
          leading: const Icon(Icons.tag),
          title: Text('#$tag'),
          onTap: () => openHashtag(context, tag),
        );
      },
    );
  }

  Widget _buildNotestockList() {
    if (_notestockLoading && _notestockResults.isEmpty) {
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
                onPressed: () => launchUrlSafely(
                  Uri.parse(
                    '${AppConstants.notestockBaseUrl}/setting/index.html',
                  ),
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
        final url = (status['url'] ?? status['id'] ?? '') as String;
        final published = status['published'] as String?;
        final date = published != null ? DateTime.tryParse(published) : null;

        // HTML タグを簡易除去して表示（カスタム絵文字の shortcode は保持）
        final plainText = content
            .replaceAll(RegExp(r'<br\s*/?>'), '\n')
            .replaceAllMapped(
              RegExp(r'<img[^>]+alt="(:[\w]+:)"[^>]*>'),
              (m) => m.group(1)!,
            )
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"')
            .replaceAll('&#39;', "'")
            .replaceAll('&nbsp;', ' ')
            .trim();

        return ListTile(
          title: Text(plainText, maxLines: 3, overflow: TextOverflow.ellipsis),
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

  Future<void> _resolveAndOpen(String url) => openFediverseLink(
    context,
    ref,
    url,
    browserMode: LaunchMode.externalApplication,
  );

  Widget _buildPostList(List<Post> posts) {
    if (posts.isEmpty) {
      return Center(child: Text('${ref.watch(postLabelProvider)}が見つかりませんでした'));
    }
    final hasMore = _hasMore(SearchKind.posts);
    return ListView.separated(
      itemCount: posts.length + (hasMore ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) => index == posts.length
          ? _moreFooter(SearchKind.posts)
          : PostTile(post: posts[index]),
    );
  }
}

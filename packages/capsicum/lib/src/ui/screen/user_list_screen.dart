import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/is_cat_provider.dart';
import '../../util/exception_scrub.dart';
import '../../util/user_acct.dart';
import '../util/op_error.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/emoji_text.dart';
import '../widget/retry_error_view.dart';
import '../widget/user_avatar.dart';

enum UserListType { followers, following, favouritedBy, rebloggedBy }

typedef UserListFetcher =
    Future<({List<User> users, String? nextCursor})> Function(String? cursor);

class UserListScreen extends StatelessWidget {
  final String title;
  final UserListFetcher fetcher;

  const UserListScreen({super.key, required this.title, required this.fetcher});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: UserListView(fetcher: fetcher),
  );
}

/// ユーザー一覧の中身だけを持つ widget (#1039)。
///
/// ⚠ **Scaffold を含めない。**タブの中に並べる用途（ブロック / ミュートの
/// 2 タブ）が出たため、[UserListScreen] から切り出した。画面として使うときは
/// [UserListScreen] が Scaffold と AppBar を被せる。
class UserListView extends ConsumerStatefulWidget {
  final UserListFetcher fetcher;

  /// 一覧が空のときの文言。既定は「ユーザーはいません」。
  final String emptyMessage;

  /// 各行の末尾に置く widget（解除ボタン等）。省略時は何も置かない。
  final Widget Function(User user)? trailingBuilder;

  const UserListView({
    super.key,
    required this.fetcher,
    this.emptyMessage = 'ユーザーはいません',
    this.trailingBuilder,
  });

  @override
  ConsumerState<UserListView> createState() => _UserListViewState();
}

class _UserListViewState extends ConsumerState<UserListView> {
  // ⚠ **ページサイズはこの View が決めない。**`fetcher` を渡す側が `limit` ごと
  // 閉じ込めている。継続の判定も `nextCursor` の有無だけで行う。
  final _scrollController = ScrollController();
  List<User> _users = [];
  String? _nextCursor;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;

  /// 初回取得の失敗 (#1039・リリース前レビューで追加)。
  ///
  /// ⚠⚠ **「0 件」と「引けない」を混ぜない。**これが無いと、取得に失敗した
  /// ときに「ブロック中のユーザーはいません」「未処理のフォローリクエストは
  /// ありません」と**アカウントの状態について誤った事実を断言する**。
  /// ブロックが消えたと誤解して再ブロックしに行く、申請が取り下げられたと
  /// 読む、といった実害が出る。同じリリースの #1041 で検索に入れた区別を、
  /// 隣で落としていた。
  Object? _error;

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
        _scrollController.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _loadInitial() async {
    try {
      final result = await widget.fetcher(null);
      if (!mounted) return;
      final enriched = await ref
          .read(isCatEnricherProvider)
          .enrichUsers(result.users);
      if (!mounted) return;
      setState(() {
        _users = enriched;
        _nextCursor = result.nextCursor;
        _loading = false;
        _error = null;
        // ⚠ **件数で判定しない**（リリース前レビューで修正）。サーバーは
        // フィルタで件数を減らしたうえで next リンクを返すことがある。
        _hasMore = result.nextCursor != null;
      });
    } catch (e) {
      debugLogException('UserListScreen load error', e);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _users.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final result = await widget.fetcher(_nextCursor);
      if (!mounted) return;
      final enriched = await ref
          .read(isCatEnricherProvider)
          .enrichUsers(result.users);
      if (!mounted) return;
      setState(() {
        _users = [..._users, ...enriched];
        _nextCursor = result.nextCursor;
        _loadingMore = false;
        _hasMore = result.nextCursor != null;
      });
    } catch (e) {
      debugLogException('UserListScreen loadMore error', e);
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BottomSafeArea(
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          // ⚠ **失敗を「0 件」と描き分ける**（リリース前レビューで追加）。
          : _error != null
          ? RetryErrorView(
              message: '読み込みに失敗しました\n${summarizeOpError(_error!)}',
              onRetry: () {
                setState(() {
                  _loading = true;
                  _error = null;
                });
                _loadInitial();
              },
            )
          : _users.isEmpty
          ? Center(child: Text(widget.emptyMessage))
          : RefreshIndicator(
              // ⚠ **`_loading` を立てない**（リリース前レビューで修正）。
              // 立てると三項の分岐が変わって RefreshIndicator ごと
              // アンマウントされ、引っ張ったスピナーが即座に消える。
              onRefresh: _loadInitial,
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
                      fallbackHost: user.host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '@${userAcct(user)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: widget.trailingBuilder?.call(user),
                  );
                },
              ),
            ),
    );
  }
}

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widget/bottom_safe_area.dart';
import '../widget/cursor_paged_list_view.dart';
import '../widget/post_tile.dart';

/// 投稿一覧をカーソルページングで出す汎用画面 (#1072)。
///
/// ⚠ **`/users`（[UserListScreen]）の投稿版。**ブースト一覧・お気に入り一覧は
/// 「その投稿に反応した**人**」なのでユーザー一覧で足りるが、引用は
/// 「その投稿を引用した**投稿**」なので中身が違う。そのまま流用できない。
///
/// ⚠ **ページングの骨格は [CursorPagedListView] が持つ (#1083-A)。**この画面が
/// 足すのは Scaffold / AppBar と `PostTile` の並べ方だけ。**世代カウンタ・
/// 「0 件」と「引けない」の描き分け・プリフェッチ閾値は向こうの正本を見ること。**
typedef PostListFetcher =
    Future<({List<Post> posts, String? nextCursor})> Function(String? cursor);

class PostListScreen extends ConsumerWidget {
  final String title;
  final PostListFetcher fetcher;

  /// 一覧が空のときの文言。
  final String emptyMessage;

  const PostListScreen({
    super.key,
    required this.title,
    required this.fetcher,
    this.emptyMessage = '投稿はありません',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: BottomSafeArea(
        child: CursorPagedListView<Post>(
          debugLabel: 'PostListScreen',
          // ⚠ **ページサイズはこの画面が決めない。**`fetcher` を渡す側が
          // `limit` ごと閉じ込めている。継続の判定も件数ではなく
          // `nextCursor` の有無だけで行う（サーバーはフィルタで件数を
          // 減らしたうえで next リンクを返すため）。
          fetcher: (cursor) async {
            final page = await fetcher(cursor);
            return (items: page.posts, nextCursor: page.nextCursor);
          },
          emptyMessage: emptyMessage,
          itemBuilder: (context, post) => PostTile(post: post),
        ),
      ),
    );
  }
}

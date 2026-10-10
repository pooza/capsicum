import '../../../capsicum_core.dart';

class PostList {
  final String id;
  final String title;

  const PostList({required this.id, required this.title});
}

abstract mixin class ListSupport {
  Future<List<PostList>> getLists();
  Future<List<Post>> getListTimeline(String listId, {TimelineQuery? query});
  Future<PostList> createList(String title);
  Future<PostList> updateList(String id, String title);
  Future<void> deleteList(String id);

  /// リストのメンバーを**全員**返す (#1202)。
  ///
  /// ⚠ **ページングしない約束。**バックエンドが既定件数で切る場合は、実装の
  /// 側で全件を取り切る（Mastodon は `limit=0`・Misskey は `userIds` が全件）。
  Future<List<User>> getListAccounts(String listId);
  Future<void> addListAccounts(String listId, List<String> accountIds);
  Future<void> removeListAccounts(String listId, List<String> accountIds);
}

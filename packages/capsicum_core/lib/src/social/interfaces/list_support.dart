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
  Future<List<User>> getListAccounts(String listId);
  Future<void> addListAccounts(String listId, List<String> accountIds);
  Future<void> removeListAccounts(String listId, List<String> accountIds);
}

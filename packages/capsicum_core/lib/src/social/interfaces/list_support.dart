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
  Future<void> deleteList(String id);
}

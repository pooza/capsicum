import '../../model/post.dart';

abstract mixin class FavoriteSupport {
  Future<Post> favoritePost(String id);
  Future<Post> unfavoritePost(String id);
}

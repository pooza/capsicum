import '../../model/post.dart';
import '../../model/user.dart';

class SearchResults {
  final List<Post> posts;
  final List<User> users;
  final List<String> hashtags;

  const SearchResults({
    this.posts = const [],
    this.users = const [],
    this.hashtags = const [],
  });
}

abstract mixin class SearchSupport {
  Future<SearchResults> search(String query);
  Future<List<User>> searchUsers(String query, {int? limit});
}

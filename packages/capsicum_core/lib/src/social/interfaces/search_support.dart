import '../../model/post.dart';
import '../../model/user.dart';

class SearchResults {
  final List<Post> posts;
  final List<User> users;

  const SearchResults({this.posts = const [], this.users = const []});
}

abstract mixin class SearchSupport {
  Future<SearchResults> search(String query);
}

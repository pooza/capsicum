import '../../model/post.dart';

abstract mixin class PinSupport {
  Future<Post> pinPost(String id);
  Future<Post> unpinPost(String id);
}

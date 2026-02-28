import 'dart:async';

import '../model/attachment.dart';
import '../model/instance.dart';
import '../model/post.dart';
import '../model/post_draft.dart';
import '../model/timeline_query.dart';
import '../model/timeline_type.dart';
import '../model/user.dart';
import 'capabilities.dart';

abstract class BackendAdapter {
  AdapterCapabilities get capabilities;

  Future<User> getMyself();
  Future<User?> getUser(String username, [String? host]);
  Future<User> getUserById(String id);
  Future<Post> postStatus(PostDraft draft);
  Future<void> deletePost(String id);
  Future<List<Post>> getTimeline(
    TimelineType type, {
    TimelineQuery? query,
  });
  Future<Post> getPostById(String id);
  Future<List<Post>> getThread(String postId);
  Future<void> repeatPost(String id);
  Future<void> unrepeatPost(String id);
  Future<Instance> getInstance();
  Future<Attachment> uploadAttachment(AttachmentDraft draft);
}

abstract class DecentralizedBackendAdapter extends BackendAdapter {
  String get host;
}

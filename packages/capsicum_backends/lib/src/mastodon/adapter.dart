import 'package:capsicum_core/capsicum_core.dart';

import 'client.dart';

class MastodonCapabilities extends AdapterCapabilities {
  @override
  Set<PostScope> get supportedScopes => {
    PostScope.public,
    PostScope.unlisted,
    PostScope.followersOnly,
    PostScope.direct,
  };

  @override
  Set<Formatting> get supportedFormattings => {Formatting.html};

  @override
  Set<TimelineType> get supportedTimelines => {
    TimelineType.home,
    TimelineType.local,
    TimelineType.federated,
  };

  @override
  int? get maxPostContentLength => 500;
}

class MastodonAdapter extends DecentralizedBackendAdapter
    with FavoriteSupport, BookmarkSupport, FollowSupport, NotificationSupport,
        SearchSupport, CustomEmojiSupport, ListSupport, HashtagSupport {
  final MastodonClient client;

  @override
  final String host;

  @override
  final AdapterCapabilities capabilities = MastodonCapabilities();

  MastodonAdapter._(this.client, this.host);

  static Future<MastodonAdapter> create(String host) async {
    final client = MastodonClient(host);
    return MastodonAdapter._(client, host);
  }

  // BackendAdapter

  @override
  Future<User> getMyself() => throw UnimplementedError();

  @override
  Future<User?> getUser(String username, [String? host]) =>
      throw UnimplementedError();

  @override
  Future<User> getUserById(String id) => throw UnimplementedError();

  @override
  Future<Post> postStatus(PostDraft draft) => throw UnimplementedError();

  @override
  Future<void> deletePost(String id) => throw UnimplementedError();

  @override
  Future<List<Post>> getTimeline(
    TimelineType type, {
    TimelineQuery? query,
  }) => throw UnimplementedError();

  @override
  Future<Post> getPostById(String id) => throw UnimplementedError();

  @override
  Future<List<Post>> getThread(String postId) => throw UnimplementedError();

  @override
  Future<void> repeatPost(String id) => throw UnimplementedError();

  @override
  Future<void> unrepeatPost(String id) => throw UnimplementedError();

  @override
  Future<Instance> getInstance() => throw UnimplementedError();

  @override
  Future<Attachment> uploadAttachment(AttachmentDraft draft) =>
      throw UnimplementedError();

  // FavoriteSupport

  @override
  Future<Post> favoritePost(String id) => throw UnimplementedError();

  @override
  Future<Post> unfavoritePost(String id) => throw UnimplementedError();

  // BookmarkSupport

  @override
  Future<Post> bookmarkPost(String id) => throw UnimplementedError();

  @override
  Future<Post> unbookmarkPost(String id) => throw UnimplementedError();

  @override
  Future<List<Post>> getBookmarks({TimelineQuery? query}) =>
      throw UnimplementedError();

  // FollowSupport

  @override
  Future<void> followUser(String id) => throw UnimplementedError();

  @override
  Future<void> unfollowUser(String id) => throw UnimplementedError();

  @override
  Future<List<User>> getFollowers(String userId) =>
      throw UnimplementedError();

  @override
  Future<List<User>> getFollowing(String userId) =>
      throw UnimplementedError();

  // NotificationSupport

  @override
  Future<List<Notification>> getNotifications() =>
      throw UnimplementedError();

  @override
  Future<void> clearAllNotifications() => throw UnimplementedError();

  // SearchSupport

  @override
  Future<SearchResults> search(String query) => throw UnimplementedError();

  // CustomEmojiSupport

  @override
  Future<List<CustomEmoji>> getEmojis() => throw UnimplementedError();

  // ListSupport

  @override
  Future<List<PostList>> getLists() => throw UnimplementedError();

  @override
  Future<PostList> createList(String title) => throw UnimplementedError();

  @override
  Future<void> deleteList(String id) => throw UnimplementedError();

  // HashtagSupport

  @override
  Future<void> followHashtag(String hashtag) => throw UnimplementedError();

  @override
  Future<void> unfollowHashtag(String hashtag) => throw UnimplementedError();

  @override
  Future<List<Post>> getPostsByHashtag(
    String hashtag, {
    TimelineQuery? query,
  }) => throw UnimplementedError();
}

import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:uuid/uuid.dart';

import 'client.dart';
import 'extensions.dart';

class MisskeyCapabilities extends AdapterCapabilities {
  @override
  Set<PostScope> get supportedScopes => {
    PostScope.public,
    PostScope.unlisted,
    PostScope.followersOnly,
    PostScope.direct,
  };

  @override
  Set<Formatting> get supportedFormattings => {Formatting.mfm};

  @override
  Set<TimelineType> get supportedTimelines => {
    TimelineType.home,
    TimelineType.local,
    TimelineType.federated,
  };

  @override
  int? get maxPostContentLength => 3000;
}

class MisskeyAdapter extends DecentralizedBackendAdapter
    with
        FavoriteSupport,
        BookmarkSupport,
        FollowSupport,
        NotificationSupport,
        SearchSupport,
        ReactionSupport,
        CustomEmojiSupport,
        ListSupport,
        HashtagSupport,
        LoginSupport {
  final MisskeyClient client;

  @override
  final String host;

  @override
  final AdapterCapabilities capabilities = MisskeyCapabilities();

  static const _permissions = [
    'read:account',
    'write:account',
    'read:blocks',
    'write:blocks',
    'read:drive',
    'write:drive',
    'read:favorites',
    'write:favorites',
    'read:following',
    'write:following',
    'read:mutes',
    'write:mutes',
    'read:notifications',
    'write:notifications',
    'write:notes',
    'read:reactions',
    'write:reactions',
    'write:votes',
  ];

  MisskeyAdapter._(this.client, this.host);

  static Future<MisskeyAdapter> create(String host) async {
    final client = MisskeyClient(host);
    return MisskeyAdapter._(client, host);
  }

  // BackendAdapter

  @override
  FutureOr<void> applySecrets(
    ClientSecretData? clientSecret,
    UserSecret userSecret,
  ) {
    client.setAccessToken(userSecret.accessToken);
  }

  @override
  Future<User> getMyself() async {
    final user = await client.getI();
    return user.toCapsicum(host);
  }

  @override
  Future<User?> getUser(String username, [String? host]) =>
      throw UnimplementedError();

  @override
  Future<User> getUserById(String id) => throw UnimplementedError();

  @override
  Future<Post> postStatus(PostDraft draft) async {
    final note = await client.createNote(
      text: draft.content ?? '',
      visibility: misskeyVisibilityFromScope(draft.scope),
      replyId: draft.inReplyToId,
    );
    return note.toCapsicum(host);
  }

  @override
  Future<void> deletePost(String id) => throw UnimplementedError();

  @override
  Future<List<Post>> getTimeline(
    TimelineType type, {
    TimelineQuery? query,
  }) async {
    final notes = switch (type) {
      TimelineType.home => await client.getTimeline(
        sinceId: query?.sinceId,
        untilId: query?.maxId,
        limit: query?.limit,
      ),
      TimelineType.local => await client.getLocalTimeline(
        sinceId: query?.sinceId,
        untilId: query?.maxId,
        limit: query?.limit,
      ),
      TimelineType.federated => await client.getGlobalTimeline(
        sinceId: query?.sinceId,
        untilId: query?.maxId,
        limit: query?.limit,
      ),
      _ => throw UnimplementedError('Timeline type $type not supported'),
    };
    return notes.map((n) => n.toCapsicum(host)).toList();
  }

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

  // LoginSupport

  @override
  Future<LoginResult> startLogin(ApplicationInfo application) async {
    try {
      final session = const Uuid().v4();
      final authUrl = Uri.https(host, '/miauth/$session', {
        'name': application.name,
        'permission': _permissions.join(','),
      });
      return LoginNeedsOAuth(
        authorizationUrl: authUrl,
        extra: {'session': session},
      );
    } catch (e, s) {
      return LoginFailure(e, s);
    }
  }

  @override
  Future<LoginResult> completeLogin(
    Uri callbackUri,
    Map<String, String> extra,
  ) async {
    try {
      final session = extra['session']!;
      final response = await client.checkSession(session);
      client.setAccessToken(response.token);

      return LoginSuccess(
        userSecret: UserSecret(accessToken: response.token),
        user: response.user.toCapsicum(host),
      );
    } catch (e, s) {
      return LoginFailure(e, s);
    }
  }

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

  // ReactionSupport

  @override
  Future<void> addReaction(String postId, String emoji) =>
      throw UnimplementedError();

  @override
  Future<void> removeReaction(String postId, String emoji) =>
      throw UnimplementedError();

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

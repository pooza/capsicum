import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';

import 'client.dart';
import 'extensions.dart';

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
    with
        FavoriteSupport,
        BookmarkSupport,
        FollowSupport,
        NotificationSupport,
        SearchSupport,
        CustomEmojiSupport,
        ListSupport,
        HashtagSupport,
        LoginSupport {
  final MastodonClient client;

  @override
  final String host;

  @override
  final AdapterCapabilities capabilities = MastodonCapabilities();

  static const _scopes = ['read', 'write', 'follow', 'push'];

  MastodonAdapter._(this.client, this.host);

  static Future<MastodonAdapter> create(String host) async {
    final client = MastodonClient(host);
    return MastodonAdapter._(client, host);
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
    final account = await client.verifyCredentials();
    return account.toCapsicum(host);
  }

  @override
  Future<User?> getUser(String username, [String? host]) =>
      throw UnimplementedError();

  @override
  Future<User> getUserById(String id) => throw UnimplementedError();

  @override
  Future<Post> postStatus(PostDraft draft) async {
    final status = await client.postStatus(
      status: draft.content ?? '',
      visibility: mastodonVisibilityFromScope(draft.scope),
      inReplyToId: draft.inReplyToId,
      spoilerText: draft.spoilerText,
    );
    return status.toCapsicum(host);
  }

  @override
  Future<void> deletePost(String id) => throw UnimplementedError();

  @override
  Future<List<Post>> getTimeline(
    TimelineType type, {
    TimelineQuery? query,
  }) async {
    final statuses = switch (type) {
      TimelineType.home => await client.getHomeTimeline(
        maxId: query?.maxId,
        sinceId: query?.sinceId,
        minId: query?.minId,
        limit: query?.limit,
      ),
      TimelineType.local => await client.getPublicTimeline(
        local: true,
        maxId: query?.maxId,
        sinceId: query?.sinceId,
        limit: query?.limit,
      ),
      TimelineType.federated => await client.getPublicTimeline(
        maxId: query?.maxId,
        sinceId: query?.sinceId,
        limit: query?.limit,
      ),
      _ => throw UnimplementedError('Timeline type $type not supported'),
    };
    return statuses.map((s) => s.toCapsicum(host)).toList();
  }

  @override
  Future<Post> getPostById(String id) async {
    final status = await client.getStatus(id);
    return status.toCapsicum(host);
  }

  @override
  Future<List<Post>> getThread(String postId) async {
    final ctx = await client.getStatusContext(postId);
    final target = await client.getStatus(postId);
    return [
      ...ctx.ancestors.map((s) => s.toCapsicum(host)),
      target.toCapsicum(host),
      ...ctx.descendants.map((s) => s.toCapsicum(host)),
    ];
  }

  @override
  Future<void> repeatPost(String id) async {
    await client.reblogStatus(id);
  }

  @override
  Future<void> unrepeatPost(String id) async {
    await client.unreblogStatus(id);
  }

  @override
  Future<Instance> getInstance() => throw UnimplementedError();

  @override
  Future<Attachment> uploadAttachment(AttachmentDraft draft) =>
      throw UnimplementedError();

  // LoginSupport

  @override
  Future<LoginResult> startLogin(ApplicationInfo application) async {
    try {
      final app = await client.createApplication(
        clientName: application.name,
        redirectUris: application.redirectUri.toString(),
        scopes: _scopes.join(' '),
        website: application.website?.toString(),
      );

      final authUrl = Uri.https(host, '/oauth/authorize', {
        'response_type': 'code',
        'client_id': app.clientId!,
        'redirect_uri': application.redirectUri.toString(),
        'scope': _scopes.join(' '),
      });

      return LoginNeedsOAuth(
        authorizationUrl: authUrl,
        extra: {
          'client_id': app.clientId!,
          'client_secret': app.clientSecret!,
          'redirect_uri': application.redirectUri.toString(),
          'scopes': _scopes.join(' '),
        },
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
      final code = callbackUri.queryParameters['code'];
      if (code == null) {
        return LoginFailure(StateError('No code in callback'));
      }

      final token = await client.getToken(
        grantType: 'authorization_code',
        clientId: extra['client_id']!,
        clientSecret: extra['client_secret']!,
        redirectUri: extra['redirect_uri']!,
        code: code,
        scope: extra['scopes'],
      );

      client.setAccessToken(token.accessToken!);
      final account = await client.verifyCredentials();

      return LoginSuccess(
        userSecret: UserSecret(accessToken: token.accessToken!),
        clientSecret: ClientSecretData(
          clientId: extra['client_id']!,
          clientSecret: extra['client_secret']!,
        ),
        user: account.toCapsicum(host),
      );
    } catch (e, s) {
      return LoginFailure(e, s);
    }
  }

  // FavoriteSupport

  @override
  Future<Post> favoritePost(String id) async {
    final status = await client.favouriteStatus(id);
    return status.toCapsicum(host);
  }

  @override
  Future<Post> unfavoritePost(String id) async {
    final status = await client.unfavouriteStatus(id);
    return status.toCapsicum(host);
  }

  // BookmarkSupport

  @override
  Future<Post> bookmarkPost(String id) async {
    final status = await client.bookmarkStatus(id);
    return status.toCapsicum(host);
  }

  @override
  Future<Post> unbookmarkPost(String id) async {
    final status = await client.unbookmarkStatus(id);
    return status.toCapsicum(host);
  }

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
  Future<List<Notification>> getNotifications({TimelineQuery? query}) async {
    final notifications = await client.getNotifications(
      maxId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
    );
    return notifications.map((n) => n.toCapsicum(host)).toList();
  }

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

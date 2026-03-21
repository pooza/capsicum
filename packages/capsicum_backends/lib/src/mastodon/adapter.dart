import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';

import 'dart:developer' as developer;

import 'client.dart';
import 'extensions.dart';
import 'streaming.dart';

/// Convert a list of items, skipping any that throw during conversion.
/// Returns the converted results, original item count, raw last ID, and
/// details of any items that failed conversion.
({List<T> results, int rawCount, String? rawLastId, List<SkippedPost> skipped})
_safeConvert<S, T>(
  List<S> items,
  T Function(S) convert,
  String Function(S) getId,
) {
  final results = <T>[];
  final skipped = <SkippedPost>[];
  for (final item in items) {
    try {
      results.add(convert(item));
    } catch (e) {
      developer.log('skipping item during conversion: $e', name: 'capsicum');
      try {
        skipped.add(SkippedPost(id: getId(item), error: '$e'));
      } catch (_) {}
    }
  }
  return (
    results: results,
    rawCount: items.length,
    rawLastId: items.isNotEmpty ? getId(items.last) : null,
    skipped: skipped,
  );
}

class MastodonCapabilities extends AdapterCapabilities {
  Set<TimelineType> _supportedTimelines = {
    TimelineType.home,
    TimelineType.local,
    TimelineType.federated,
  };

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
  Set<TimelineType> get supportedTimelines => _supportedTimelines;

  set supportedTimelines(Set<TimelineType> value) =>
      _supportedTimelines = value;

  @override
  int? get maxPostContentLength => 500;
}

class MastodonAdapter extends DecentralizedBackendAdapter
    with
        FavoriteSupport,
        BookmarkSupport,
        AnnouncementSupport,
        FollowSupport,
        NotificationSupport,
        SearchSupport,
        CustomEmojiSupport,
        ListSupport,
        HashtagSupport,
        PollSupport,
        LoginSupport,
        StreamSupport,
        MarkerSupport,
        ProfileEditSupport,
        ReportSupport {
  final MastodonClient client;
  MastodonStreaming? _streaming;

  @override
  final String host;

  @override
  final MastodonCapabilities capabilities = MastodonCapabilities();

  static const _scopes = ['read', 'write', 'follow', 'push'];

  MastodonAdapter._(this.client, this.host);

  static Future<MastodonAdapter> create(String host) async {
    final client = MastodonClient(host);
    return MastodonAdapter._(client, host);
  }

  /// Detect which public timelines are available on this server.
  ///
  /// First tries Mastodon 4.5+ `timelines_access` from `/api/v2/instance`.
  /// Falls back to probing the public timeline API with 403 detection.
  Future<void> detectTimelineAvailability() async {
    var localEnabled = true;
    var federatedEnabled = true;

    try {
      // Try v2 instance API (Mastodon 4.5+).
      final instance = await client.getInstanceV2();
      final config = instance['configuration'] as Map<String, dynamic>?;
      final access = config?['timelines_access'] as Map<String, dynamic>?;
      if (access != null) {
        final liveFeeds = access['live_feeds'] as Map<String, dynamic>?;
        if (liveFeeds != null) {
          localEnabled = liveFeeds['local'] != 'disabled';
          federatedEnabled = liveFeeds['remote'] != 'disabled';
        }
      } else {
        // No timelines_access field — fall back to probing.
        localEnabled = await client.probePublicTimeline(local: true);
        federatedEnabled = await client.probePublicTimeline();
      }
    } catch (_) {
      // v2 instance API failed — fall back to probing.
      try {
        localEnabled = await client.probePublicTimeline(local: true);
        federatedEnabled = await client.probePublicTimeline();
      } catch (_) {
        // Probing also failed; keep defaults.
      }
    }

    capabilities.supportedTimelines = {
      TimelineType.home,
      if (localEnabled) TimelineType.local,
      if (federatedEnabled) TimelineType.federated,
    };
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
  Future<User?> getUser(String username, [String? remoteHost]) async {
    final acct = remoteHost != null ? '$username@$remoteHost' : username;
    final account = await client.lookupAccount(acct);
    return account?.toCapsicum(host);
  }

  @override
  Future<User> getUserById(String id) async {
    final account = await client.getAccount(id);
    return account.toCapsicum(host);
  }

  Future<List<Post>> getUserPosts(String id, {String? maxId}) async {
    final statuses = await client.getAccountStatuses(
      id,
      maxId: maxId,
      limit: 20,
    );
    return _safeConvert(
      statuses,
      (s) => s.toCapsicum(host),
      (s) => s.id,
    ).results;
  }

  Future<List<Post>> getPinnedPosts(String id) async {
    final statuses = await client.getAccountStatuses(id, pinned: true);
    return _safeConvert(
      statuses,
      (s) => s.toCapsicum(host, pinned: true),
      (s) => s.id,
    ).results;
  }

  @override
  Future<Post> postStatus(PostDraft draft) async {
    final status = await client.postStatus(
      status: draft.content ?? '',
      visibility: mastodonVisibilityFromScope(draft.scope),
      inReplyToId: draft.inReplyToId,
      spoilerText: draft.spoilerText,
      mediaIds: draft.mediaIds.isNotEmpty ? draft.mediaIds : null,
      sensitive: draft.sensitive ? true : null,
      extraHeaders: draft.skipMulukhiya ? {'X-Mulukhiya': 'capsicum'} : null,
    );
    return status.toCapsicum(host);
  }

  @override
  Future<void> deletePost(String id) async {
    await client.deleteStatus(id);
  }

  @override
  Future<TimelineResponse> getTimeline(
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
    final converted = _safeConvert(
      statuses,
      (s) => s.toCapsicum(host),
      (s) => s.id,
    );
    return TimelineResponse(
      posts: converted.results,
      rawCount: converted.rawCount,
      rawLastId: converted.rawLastId,
      skippedPosts: converted.skipped,
    );
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
  Future<Post> repeatPost(String id) async {
    final status = await client.reblogStatus(id);
    final post = status.toCapsicum(host);
    // reblog API returns a wrapper post; extract the original with updated counts.
    return post.reblog ?? post;
  }

  @override
  Future<Post> unrepeatPost(String id) async {
    final status = await client.unreblogStatus(id);
    return status.toCapsicum(host);
  }

  @override
  Future<Instance> getInstance() => throw UnimplementedError();

  @override
  Future<Attachment> uploadAttachment(AttachmentDraft draft) async {
    var media = await client.uploadMedia(
      draft.filePath,
      mimeType: draft.mimeType,
    );
    if (draft.description != null && draft.description!.isNotEmpty) {
      media = await client.updateMedia(
        media.id,
        description: draft.description,
      );
    }
    return media.toCapsicum();
  }

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
  Future<List<Post>> getBookmarks({TimelineQuery? query}) async {
    final statuses = await client.getBookmarks(
      maxId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
    );
    return _safeConvert(
      statuses,
      (s) => s.toCapsicum(host),
      (s) => s.id,
    ).results;
  }

  // AnnouncementSupport

  @override
  Future<List<Announcement>> getAnnouncements() async {
    final announcements = await client.getAnnouncements();
    return announcements.reversed.map((a) => a.toCapsicum()).toList();
  }

  @override
  Future<void> dismissAnnouncement(String id) => client.dismissAnnouncement(id);

  // FollowSupport

  @override
  Future<UserRelationship> getRelationship(String userId) async {
    final rels = await client.getRelationships([userId]);
    if (rels.isEmpty) return const UserRelationship();
    final r = rels.first;
    return UserRelationship(
      following: r['following'] as bool? ?? false,
      followedBy: r['followed_by'] as bool? ?? false,
      muting: r['muting'] as bool? ?? false,
      blocking: r['blocking'] as bool? ?? false,
    );
  }

  @override
  Future<void> followUser(String id) => client.followAccount(id);

  @override
  Future<void> unfollowUser(String id) => client.unfollowAccount(id);

  @override
  Future<void> muteUser(String id, {Duration? duration}) =>
      client.muteAccount(id, duration: duration?.inSeconds);

  @override
  Future<void> unmuteUser(String id) => client.unmuteAccount(id);

  @override
  Future<void> blockUser(String id) => client.blockAccount(id);

  @override
  Future<void> unblockUser(String id) => client.unblockAccount(id);

  @override
  Future<({List<User> users, String? nextCursor})> getFollowers(
    String userId, {
    TimelineQuery? query,
  }) async {
    final result = await client.getAccountFollowers(
      userId,
      maxId: query?.maxId,
      limit: query?.limit,
    );
    return (
      users: result.accounts.map((a) => a.toCapsicum(client.host)).toList(),
      nextCursor: result.nextMaxId,
    );
  }

  @override
  Future<({List<User> users, String? nextCursor})> getFollowing(
    String userId, {
    TimelineQuery? query,
  }) async {
    final result = await client.getAccountFollowing(
      userId,
      maxId: query?.maxId,
      limit: query?.limit,
    );
    return (
      users: result.accounts.map((a) => a.toCapsicum(client.host)).toList(),
      nextCursor: result.nextMaxId,
    );
  }

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
  Future<SearchResults> search(String query) async {
    final isUrl = Uri.tryParse(query)?.hasScheme ?? false;
    final data = await client.search(
      query,
      resolve: isUrl ? true : null,
      limit: 20,
    );
    final accounts = (data['accounts'] as List? ?? [])
        .map((e) => MastodonAccount.fromJson(e as Map<String, dynamic>))
        .map((a) => a.toCapsicum(host))
        .toList();
    final statuses = (data['statuses'] as List? ?? [])
        .map((e) => MastodonStatus.fromJson(e as Map<String, dynamic>))
        .map((s) => s.toCapsicum(host))
        .toList();
    final hashtags = (data['hashtags'] as List? ?? [])
        .map((e) => (e as Map<String, dynamic>)['name'] as String)
        .toList();
    return SearchResults(users: accounts, posts: statuses, hashtags: hashtags);
  }

  @override
  Future<List<User>> searchUsers(String query, {int? limit}) async {
    final accounts = await client.searchAccounts(query, limit: limit);
    return accounts.map((a) => a.toCapsicum(host)).toList();
  }

  @override
  Future<List<String>> searchHashtags(String query, {int? limit}) async {
    final data = await client.search(query, type: 'hashtags', limit: limit);
    return (data['hashtags'] as List? ?? [])
        .map((e) => (e as Map<String, dynamic>)['name'] as String)
        .toList();
  }

  // CustomEmojiSupport

  @override
  Future<List<CustomEmoji>> getEmojis() async {
    final emojis = await client.getCustomEmojis();
    return emojis
        .where((e) => e['visible_in_picker'] != false)
        .map(
          (e) => CustomEmoji(
            shortcode: e['shortcode'] as String,
            url: (e['static_url'] as String?) ?? (e['url'] as String?) ?? '',
            category: e['category'] as String?,
          ),
        )
        .toList();
  }

  // ListSupport

  @override
  Future<List<PostList>> getLists() async {
    final lists = await client.getLists();
    return lists.map((l) => l.toCapsicum()).toList();
  }

  @override
  Future<List<Post>> getListTimeline(
    String listId, {
    TimelineQuery? query,
  }) async {
    final statuses = await client.getListTimeline(
      listId,
      maxId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
    );
    return _safeConvert(
      statuses,
      (s) => s.toCapsicum(host),
      (s) => s.id,
    ).results;
  }

  @override
  Future<PostList> createList(String title) async {
    final list = await client.createList(title);
    return list.toCapsicum();
  }

  @override
  Future<PostList> updateList(String id, String title) async {
    final list = await client.updateList(id, title);
    return list.toCapsicum();
  }

  @override
  Future<void> deleteList(String id) async {
    await client.deleteList(id);
  }

  @override
  Future<List<User>> getListAccounts(String listId) async {
    final accounts = await client.getListAccounts(listId);
    return accounts.map((a) => a.toCapsicum(host)).toList();
  }

  @override
  Future<void> addListAccounts(String listId, List<String> accountIds) async {
    // Mastodon (pre-4.2) requires following accounts before adding to a list.
    // Follow any unfollowed accounts first.
    final rels = await client.getRelationships(accountIds);
    for (final rel in rels) {
      if (rel['following'] != true) {
        await client.followAccount(rel['id'] as String);
      }
    }
    await client.addListAccounts(listId, accountIds);
  }

  @override
  Future<void> removeListAccounts(
    String listId,
    List<String> accountIds,
  ) async {
    await client.removeListAccounts(listId, accountIds);
  }

  // MarkerSupport

  @override
  Future<MarkerSet> getMarkers() async {
    final data = await client.getMarkers(['home', 'notifications']);
    return MarkerSet(
      home: _parseMarker(data['home'] as Map<String, dynamic>?),
      notifications: _parseMarker(
        data['notifications'] as Map<String, dynamic>?,
      ),
    );
  }

  Marker? _parseMarker(Map<String, dynamic>? data) {
    if (data == null) return null;
    return Marker(
      lastReadId: data['last_read_id'] as String,
      version: data['version'] as int,
      updatedAt: DateTime.parse(data['updated_at'] as String),
    );
  }

  @override
  Future<void> saveHomeMarker(String lastReadId) async {
    await client.saveMarkers(homeLastReadId: lastReadId);
  }

  @override
  Future<void> saveNotificationMarker(String lastReadId) async {
    await client.saveMarkers(notificationLastReadId: lastReadId);
  }

  // HashtagSupport

  @override
  Future<void> followHashtag(String hashtag) => throw UnimplementedError();

  @override
  Future<void> unfollowHashtag(String hashtag) => throw UnimplementedError();

  @override
  Future<List<Post>> getPostsByHashtag(
    String hashtag, {
    TimelineQuery? query,
  }) async {
    final statuses = await client.getTagTimeline(
      hashtag,
      maxId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
    );
    return _safeConvert(
      statuses,
      (s) => s.toCapsicum(host),
      (s) => s.id,
    ).results;
  }

  // PollSupport

  @override
  Future<void> votePoll(String pollId, List<int> choices) async {
    await client.votePoll(pollId, choices);
  }

  // StreamSupport

  @override
  Stream<Post> streamTimeline(TimelineType type) {
    _streaming?.dispose();
    final token = client.accessToken;
    if (token == null) return const Stream.empty();
    _streaming = MastodonStreaming(host: host, accessToken: token);
    return _streaming!.connect(type);
  }

  @override
  void disposeStream() {
    _streaming?.dispose();
    _streaming = null;
  }

  // ProfileEditSupport

  @override
  Future<int?> getMaxProfileFields() async {
    try {
      final instance = await client.getInstanceV1();
      final config = instance['configuration'] as Map<String, dynamic>?;
      final accounts = config?['accounts'] as Map<String, dynamic>?;
      return accounts?['max_profile_fields'] as int? ?? 4;
    } catch (_) {
      return 4;
    }
  }

  @override
  Future<User> updateProfile({
    String? displayName,
    String? description,
    String? avatarFilePath,
    String? bannerFilePath,
    List<UserField>? fields,
  }) async {
    final account = await client.updateCredentials(
      displayName: displayName,
      note: description,
      avatarPath: avatarFilePath,
      headerPath: bannerFilePath,
      fieldsAttributes: fields
          ?.map((f) => {'name': f.name, 'value': f.value})
          .toList(),
    );
    return account.toCapsicum(host);
  }

  // ReportSupport

  @override
  Future<void> reportPost(
    String postId,
    String authorId, {
    String? comment,
  }) async {
    await client.createReport(authorId, statusIds: [postId], comment: comment);
  }
}

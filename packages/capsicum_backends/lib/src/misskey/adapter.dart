import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:uuid/uuid.dart';

import 'client.dart';
import 'extensions.dart';
import 'streaming.dart';

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
    TimelineType.social,
    TimelineType.federated,
  };

  @override
  int? get maxPostContentLength => 3000;
}

class MisskeyAdapter extends DecentralizedBackendAdapter
    with
        BookmarkSupport,
        FollowSupport,
        NotificationSupport,
        SearchSupport,
        ReactionSupport,
        CustomEmojiSupport,
        ListSupport,
        HashtagSupport,
        LoginSupport,
        StreamSupport {
  MisskeyStreaming? _streaming;
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
      fileIds: draft.mediaIds.isNotEmpty ? draft.mediaIds : null,
    );
    return note.toCapsicum(host);
  }

  @override
  Future<void> deletePost(String id) async {
    await client.deleteNote(id);
  }

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
      TimelineType.social => await client.getHybridTimeline(
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
  Future<Post> getPostById(String id) async {
    final note = await client.getNote(id);
    return note.toCapsicum(host);
  }

  @override
  Future<List<Post>> getThread(String postId) async {
    final target = await client.getNote(postId);
    final children = await client.getNoteChildren(noteId: postId, limit: 100);

    // Walk up the reply chain to get ancestors.
    final ancestors = <Post>[];
    var currentNote = target;
    while (currentNote.replyId != null) {
      final parent = await client.getNote(currentNote.replyId!);
      ancestors.insert(0, parent.toCapsicum(host));
      currentNote = parent;
    }

    return [
      ...ancestors,
      target.toCapsicum(host),
      ...children.map((n) => n.toCapsicum(host)),
    ];
  }

  @override
  Future<void> repeatPost(String id) async {
    await client.renote(id);
  }

  @override
  Future<void> unrepeatPost(String id) => throw UnimplementedError();

  @override
  Future<Instance> getInstance() => throw UnimplementedError();

  @override
  Future<Attachment> uploadAttachment(AttachmentDraft draft) async {
    final file = await client.createDriveFile(
      draft.filePath,
      comment: draft.description,
      mimeType: draft.mimeType,
    );
    return Attachment(
      id: file['id'] as String,
      type: _driveFileType(file['type'] as String?),
      url: file['url'] as String,
      previewUrl: file['thumbnailUrl'] as String?,
      description: file['comment'] as String?,
    );
  }

  static AttachmentType _driveFileType(String? mimeType) {
    if (mimeType == null) return AttachmentType.unknown;
    if (mimeType.startsWith('image/')) return AttachmentType.image;
    if (mimeType.startsWith('video/')) return AttachmentType.video;
    if (mimeType.startsWith('audio/')) return AttachmentType.audio;
    return AttachmentType.unknown;
  }

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

  // BookmarkSupport (Misskey の「お気に入り」= Mastodon のブックマーク相当)

  @override
  Future<Post> bookmarkPost(String id) async {
    await client.favoriteNote(id);
    final note = await client.getNote(id);
    return note.toCapsicum(host);
  }

  @override
  Future<Post> unbookmarkPost(String id) async {
    await client.unfavoriteNote(id);
    final note = await client.getNote(id);
    return note.toCapsicum(host);
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
      sinceId: query?.sinceId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    return notifications.map((n) => n.toCapsicum(host)).toList();
  }

  @override
  Future<void> clearAllNotifications() => throw UnimplementedError();

  // SearchSupport

  @override
  Future<SearchResults> search(String query) => throw UnimplementedError();

  // ReactionSupport

  @override
  Future<void> addReaction(String postId, String emoji) async {
    await client.createReaction(postId, emoji);
  }

  @override
  Future<void> removeReaction(String postId, String emoji) async {
    await client.deleteReaction(postId);
  }

  // CustomEmojiSupport

  @override
  Future<List<CustomEmoji>> getEmojis() async {
    final emojis = await client.getEmojis();
    return emojis
        .map(
          (e) => CustomEmoji(
            shortcode: e['name'] as String,
            url: (e['url'] as String?) ?? '',
            category: e['category'] as String?,
          ),
        )
        .toList();
  }

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

  // StreamSupport

  @override
  Stream<Post> streamTimeline(TimelineType type) {
    _streaming?.dispose();
    final token = client.accessToken;
    if (token == null) return const Stream.empty();
    _streaming = MisskeyStreaming(host: host, accessToken: token);
    return _streaming!.connect(type);
  }

  @override
  void disposeStream() {
    _streaming?.dispose();
    _streaming = null;
  }
}

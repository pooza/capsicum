import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:uuid/uuid.dart';

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
        AnnouncementSupport,
        FollowSupport,
        NotificationSupport,
        SearchSupport,
        ReactionSupport,
        CustomEmojiSupport,
        ListSupport,
        HashtagSupport,
        PollSupport,
        LoginSupport,
        StreamSupport {
  MisskeyStreaming? _streaming;
  final MisskeyClient client;
  List<List<String>> _mutedWords = [];
  List<List<String>> _hardMutedWords = [];

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
    _mutedWords = user.mutedWords ?? [];
    _hardMutedWords = user.hardMutedWords ?? [];
    return user.toCapsicum(host);
  }

  @override
  Future<User?> getUser(String username, [String? host]) =>
      throw UnimplementedError();

  @override
  Future<User> getUserById(String id) async {
    final user = await client.showUser(id);
    return user.toCapsicum(host);
  }

  Future<List<Post>> getUserPosts(String id, {String? maxId}) async {
    final notes = await client.getUserNotes(id, untilId: maxId, limit: 20);
    return _safeConvert(notes, (n) => n.toCapsicum(host), (n) => n.id).results;
  }

  Future<List<Post>> getPinnedPosts(String id) async {
    final notes = await client.getUserNotes(id, pinned: true);
    return _safeConvert(
      notes,
      (n) => n.toCapsicum(host, pinned: true),
      (n) => n.id,
    ).results;
  }

  @override
  Future<Post> postStatus(PostDraft draft) async {
    final note = await client.createNote(
      text: draft.content ?? '',
      visibility: misskeyVisibilityFromScope(draft.scope),
      replyId: draft.inReplyToId,
      fileIds: draft.mediaIds.isNotEmpty ? draft.mediaIds : null,
      cw: draft.spoilerText,
      localOnly: draft.localOnly ? true : null,
      extraHeaders: draft.skipMulukhiya ? {'X-Mulukhiya': 'capsicum'} : null,
    );
    return note.toCapsicum(host);
  }

  @override
  Future<void> deletePost(String id) async {
    await client.deleteNote(id);
  }

  @override
  Future<TimelineResponse> getTimeline(
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
    final converted = _safeConvert(
      notes,
      (n) => n.toCapsicum(host),
      (n) => n.id,
    );
    final posts = converted.results.map(_applyWordFilter).toList();
    return TimelineResponse(
      posts: posts,
      rawCount: converted.rawCount,
      rawLastId: converted.rawLastId,
      skippedPosts: converted.skipped,
    );
  }

  Post _applyWordFilter(Post post) {
    if (_mutedWords.isEmpty && _hardMutedWords.isEmpty) return post;
    final text = '${post.content ?? ''} ${post.spoilerText ?? ''}'
        .toLowerCase();
    if (text.trim().isEmpty) return post;

    if (_matchesMuteWords(text, _hardMutedWords)) {
      return Post(
        id: post.id,
        postedAt: post.postedAt,
        author: post.author,
        content: post.content,
        scope: post.scope,
        attachments: post.attachments,
        favouriteCount: post.favouriteCount,
        reblogCount: post.reblogCount,
        replyCount: post.replyCount,
        favourited: post.favourited,
        reblogged: post.reblogged,
        bookmarked: post.bookmarked,
        sensitive: post.sensitive,
        reactions: post.reactions,
        myReaction: post.myReaction,
        reactionEmojis: post.reactionEmojis,
        inReplyToId: post.inReplyToId,
        reblog: post.reblog,
        spoilerText: post.spoilerText,
        emojis: post.emojis,
        emojiHost: post.emojiHost,
        pinned: post.pinned,
        filterAction: FilterAction.hide,
        filterTitle: 'ワードミュート',
      );
    }
    if (_matchesMuteWords(text, _mutedWords)) {
      return Post(
        id: post.id,
        postedAt: post.postedAt,
        author: post.author,
        content: post.content,
        scope: post.scope,
        attachments: post.attachments,
        favouriteCount: post.favouriteCount,
        reblogCount: post.reblogCount,
        replyCount: post.replyCount,
        favourited: post.favourited,
        reblogged: post.reblogged,
        bookmarked: post.bookmarked,
        sensitive: post.sensitive,
        reactions: post.reactions,
        myReaction: post.myReaction,
        reactionEmojis: post.reactionEmojis,
        inReplyToId: post.inReplyToId,
        reblog: post.reblog,
        spoilerText: post.spoilerText,
        emojis: post.emojis,
        emojiHost: post.emojiHost,
        pinned: post.pinned,
        filterAction: FilterAction.warn,
        filterTitle: 'ワードミュート',
      );
    }
    return post;
  }

  static bool _matchesMuteWords(String text, List<List<String>> muteWords) {
    for (final group in muteWords) {
      if (group.isEmpty) continue;
      // Single-element group starting with "/" is a regex pattern.
      if (group.length == 1 &&
          group[0].startsWith('/') &&
          group[0].endsWith('/')) {
        final pattern = group[0].substring(1, group[0].length - 1);
        try {
          if (RegExp(pattern, caseSensitive: false).hasMatch(text)) return true;
        } catch (_) {
          // Invalid regex — skip.
        }
        continue;
      }
      // Multi-element group: all words must match (AND condition).
      final allMatch = group.every((word) => text.contains(word.toLowerCase()));
      if (allMatch) return true;
    }
    return false;
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
  Future<Post> repeatPost(String id) async {
    final note = await client.renote(id);
    return note.toCapsicum(host);
  }

  @override
  Future<Post> unrepeatPost(String id) => throw UnimplementedError();

  @override
  Future<Instance> getInstance() => throw UnimplementedError();

  @override
  Future<Attachment> uploadAttachment(AttachmentDraft draft) async {
    final file = await client.createDriveFile(
      draft.filePath,
      comment: draft.description,
      mimeType: draft.mimeType,
      isSensitive: draft.sensitive ? true : null,
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
        'callback': application.redirectUri.toString(),
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
  Future<List<Post>> getBookmarks({TimelineQuery? query}) async {
    final notes = await client.getFavorites(
      untilId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
    );
    return _safeConvert(notes, (n) => n.toCapsicum(host), (n) => n.id).results;
  }

  // AnnouncementSupport

  @override
  Future<List<Announcement>> getAnnouncements() async {
    final announcements = await client.getAnnouncements();
    return announcements.map((a) => a.toCapsicum()).toList();
  }

  @override
  Future<void> dismissAnnouncement(String id) => client.readAnnouncement(id);

  // FollowSupport

  @override
  Future<UserRelationship> getRelationship(String userId) async {
    final r = await client.getUserRelation(userId);
    return UserRelationship(
      following: r['isFollowing'] as bool? ?? false,
      followedBy: r['isFollowed'] as bool? ?? false,
      muting: r['isMuted'] as bool? ?? false,
      blocking: r['isBlocking'] as bool? ?? false,
    );
  }

  @override
  Future<void> followUser(String id) => client.followUser(id);

  @override
  Future<void> unfollowUser(String id) => client.unfollowUser(id);

  @override
  Future<void> muteUser(String id, {Duration? duration}) {
    final expiresAt = duration != null && duration.inMilliseconds > 0
        ? DateTime.now().add(duration).millisecondsSinceEpoch
        : null;
    return client.muteUser(id, expiresAt: expiresAt);
  }

  @override
  Future<void> unmuteUser(String id) => client.unmuteUser(id);

  @override
  Future<void> blockUser(String id) => client.blockUser(id);

  @override
  Future<void> unblockUser(String id) => client.unblockUser(id);

  @override
  Future<({List<User> users, String? nextCursor})> getFollowers(
    String userId, {
    TimelineQuery? query,
  }) async {
    final items = await client.getUserFollowers(
      userId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    final users = items.map((item) {
      final userData = item['follower'] as Map<String, dynamic>;
      return MisskeyUser.fromJson(userData).toCapsicum(client.host);
    }).toList();
    return (users: users, nextCursor: users.lastOrNull?.id);
  }

  @override
  Future<({List<User> users, String? nextCursor})> getFollowing(
    String userId, {
    TimelineQuery? query,
  }) async {
    final items = await client.getUserFollowing(
      userId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    final users = items.map((item) {
      final userData = item['followee'] as Map<String, dynamic>;
      return MisskeyUser.fromJson(userData).toCapsicum(client.host);
    }).toList();
    return (users: users, nextCursor: users.lastOrNull?.id);
  }

  // NotificationSupport

  @override
  Future<List<Notification>> getNotifications({TimelineQuery? query}) async {
    final notifications = await client.getNotifications(
      sinceId: query?.sinceId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    return _safeConvert(
      notifications,
      (n) => n.toCapsicum(host),
      (n) => n.id,
    ).results;
  }

  @override
  Future<void> clearAllNotifications() => throw UnimplementedError();

  // SearchSupport

  @override
  Future<SearchResults> search(String query) async {
    final isUrl = Uri.tryParse(query)?.hasScheme ?? false;

    if (isUrl) {
      try {
        final data = await client.apShow(query);
        final type = data['type'] as String?;
        if (type == 'Note') {
          final note = MisskeyNote.fromJson(
            data['object'] as Map<String, dynamic>,
          );
          return SearchResults(posts: [note.toCapsicum(host)]);
        } else if (type == 'User') {
          final user = MisskeyUser.fromJson(
            data['object'] as Map<String, dynamic>,
          );
          return SearchResults(users: [user.toCapsicum(host)]);
        }
      } catch (_) {
        // resolve failed — return empty results.
      }
      return const SearchResults();
    }

    final users = await client.searchUsers(query, limit: 20);
    final hashtags = await client.searchHashtags(query, limit: 20);
    return SearchResults(
      users: users.map((u) => u.toCapsicum(host)).toList(),
      hashtags: hashtags,
    );
  }

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
  Future<List<PostList>> getLists() async {
    final lists = await client.getLists();
    return lists.map((l) => l.toCapsicum()).toList();
  }

  @override
  Future<List<Post>> getListTimeline(
    String listId, {
    TimelineQuery? query,
  }) async {
    final notes = await client.getUserListTimeline(
      listId,
      sinceId: query?.sinceId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    return notes.map((n) => n.toCapsicum(host)).map(_applyWordFilter).toList();
  }

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
  }) async {
    final notes = await client.searchByTag(
      hashtag,
      sinceId: query?.sinceId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    return notes.map((n) => n.toCapsicum(host)).map(_applyWordFilter).toList();
  }

  // PollSupport

  @override
  Future<void> votePoll(String pollId, List<int> choices) async {
    for (final choice in choices) {
      await client.votePoll(pollId, choice);
    }
  }

  // StreamSupport

  @override
  Stream<Post> streamTimeline(TimelineType type) {
    _streaming?.dispose();
    final token = client.accessToken;
    if (token == null) return const Stream.empty();
    _streaming = MisskeyStreaming(host: host, accessToken: token);
    return _streaming!.connect(type).map(_applyWordFilter);
  }

  @override
  void disposeStream() {
    _streaming?.dispose();
    _streaming = null;
  }
}

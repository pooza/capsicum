import 'dart:async';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:uuid/uuid.dart';

import 'dart:developer' as developer;

import 'chat_room_streaming.dart';
import 'chat_streaming.dart';
import 'client.dart';
import 'extensions.dart';
import 'notification_streaming.dart';
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
        AchievementSupport,
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
        StreamSupport,
        NotificationStreamSupport,
        MediaUpdateSupport,
        ProfileEditSupport,
        ChannelSupport,
        ClipSupport,
        FlashSupport,
        GallerySupport,
        AntennaSupport,
        ReportSupport,
        PinSupport,
        PushSubscriptionSupport,
        ScheduleSupport,
        TranslationSupport,
        DriveSupport,
        PagesSupport,
        ChatSupport {
  MisskeyStreaming? _streaming;
  MisskeyNotificationStreaming? _notificationStreaming;
  MisskeyChatStreaming? _chatStreaming;
  // ルーム毎に 1 本ずつ WebSocket を張る (chatRoom channel は roomId 必須で
  // aggregate 不可、#438)。表示中のルームに対して都度購読 / 切断する。
  final Map<String, MisskeyChatRoomStreaming> _chatRoomStreamings = {};
  final MisskeyClient client;
  List<List<String>> _mutedWords = [];
  List<List<String>> _hardMutedWords = [];
  final Set<String> _adminRoleIds = {};
  User? _myUser;
  // _canWriteChat は user.canChat (chatAvailability == 'available') と一致。
  // readonly / unavailable はどちらも false。
  // 読み取り側は permissive に倒す方針なので flag を持たず、`canReadChat`
  // は常に true を返す (#446)。
  bool _canWriteChat = true;

  void applyAdminRoleIds(List<String> ids) => _adminRoleIds.addAll(ids);

  @override
  final String host;

  @override
  final AdapterCapabilities capabilities = MisskeyCapabilities();

  static const _permissions = [
    'read:account',
    'write:account',
    'read:blocks',
    'write:blocks',
    'read:channels',
    'write:channels',
    'read:chat',
    'write:chat',
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
    // Pages の「いいね」一覧取得 (i/page-likes) と like/unlike (#615 / #617)。
    // これが無いと getLikedPages / likePage が permission denied で失敗する。
    'read:page-likes',
    'write:page-likes',
    'read:reactions',
    'write:reactions',
    'write:report-abuse',
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
    // canChat は roleService.getUserPolicies(...).chatAvailability === 'available'
    // をサーバー側で boolean 化したもの (UserEntityService.ts:561)。Misskey が
    // フィールドを返さない古いフォーク・bot 不許可ロール等では null になる。
    // 書き込み (canWriteChat) は strictly available のみ true。読み取り側
    // (canReadChat) は permissive 方針で常に true (#446)。
    _canWriteChat = user.canChat ?? false;
    final me = user.toCapsicum(host, adminRoleIds: _adminRoleIds);
    _myUser = me;
    return me;
  }

  @override
  Future<User?> getUser(String username, [String? remoteHost]) async {
    final user = await client.showUserByName(username, remoteHost);
    return user?.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  @override
  Future<User> getUserById(String id) async {
    final user = await client.showUser(id);
    return user.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  Future<List<Post>> getUserPosts(
    String id, {
    String? maxId,
    bool? onlyMedia,
  }) async {
    final notes = await client.getUserNotes(
      id,
      untilId: maxId,
      limit: 20,
      withFiles: onlyMedia,
    );
    return _safeConvert(
      notes,
      (n) => n.toCapsicum(host, adminRoleIds: _adminRoleIds),
      (n) => n.id,
    ).results;
  }

  Future<List<Post>> getPinnedPosts(String id) async {
    final user = await client.showUser(id);
    final rawNotes = user.pinnedNotes ?? [];
    final notes = rawNotes.map((e) => MisskeyNote.fromJson(e)).toList();
    return _safeConvert(
      notes,
      (n) => n.toCapsicum(host, pinned: true, adminRoleIds: _adminRoleIds),
      (n) => n.id,
    ).results;
  }

  @override
  Future<Post?> postStatus(PostDraft draft) async {
    if (draft.scheduledAt != null) {
      await client.createScheduledNote(
        text: draft.content ?? '',
        visibility: misskeyVisibilityFromScope(draft.scope),
        scheduledAt: draft.scheduledAt!,
        replyId: draft.inReplyToId,
        renoteId: draft.quoteId,
        fileIds: draft.mediaIds.isNotEmpty ? draft.mediaIds : null,
        cw: draft.spoilerText,
        localOnly: draft.localOnly ? true : null,
        channelId: draft.channelId,
      );
      return null;
    }
    Map<String, dynamic>? poll;
    if (draft.pollOptions != null && draft.pollOptions!.isNotEmpty) {
      poll = {
        'choices': draft.pollOptions,
        'multiple': draft.pollMultiple,
        if (draft.pollExpiresIn != null)
          'expiredAfter': draft.pollExpiresIn! * 1000,
      };
    }
    final note = await client.createNote(
      text: draft.content ?? '',
      visibility: misskeyVisibilityFromScope(draft.scope),
      replyId: draft.inReplyToId,
      renoteId: draft.quoteId,
      fileIds: draft.mediaIds.isNotEmpty ? draft.mediaIds : null,
      cw: draft.spoilerText,
      localOnly: draft.localOnly ? true : null,
      channelId: draft.channelId,
      poll: poll,
      extraHeaders: draft.skipMulukhiya ? {'X-Mulukhiya': 'capsicum'} : null,
    );
    return note.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  @override
  Future<List<ScheduledPost>> getScheduledPosts() async {
    return client.getScheduledNotes();
  }

  @override
  Future<void> cancelScheduledPost(String id) async {
    await client.deleteScheduledNote(id);
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
      (n) => n.toCapsicum(host, adminRoleIds: _adminRoleIds),
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
        isHtml: post.isHtml,
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
        isHtml: post.isHtml,
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
    return note.toCapsicum(host, adminRoleIds: _adminRoleIds);
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
      ancestors.insert(0, parent.toCapsicum(host, adminRoleIds: _adminRoleIds));
      currentNote = parent;
    }

    return [
      ...ancestors,
      target.toCapsicum(host, adminRoleIds: _adminRoleIds),
      ...children.map((n) => n.toCapsicum(host, adminRoleIds: _adminRoleIds)),
    ];
  }

  @override
  Future<Post> repeatPost(String id, {PostScope? visibility}) async {
    final note = await client.renote(
      id,
      visibility: visibility != null
          ? misskeyVisibilityRosetta.entries
                .firstWhere((e) => e.value == visibility)
                .key
          : null,
    );
    return note.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  @override
  Future<void> unrepeatPost(Post post) => client.deleteNote(post.id);

  @override
  Future<Instance> getInstance() async {
    final data = await client.getMeta();
    final rulesRaw = data['serverRules'] as List<dynamic>? ?? [];
    final rules = rulesRaw
        .map((r) {
          if (r is Map<String, dynamic>) return r['text'] as String? ?? '';
          if (r is String) return r;
          return '';
        })
        .where((t) => t.isNotEmpty)
        .toList();

    // Misskey は MIME によらず単一値（bytes）。image/video/audio すべてに
    // 同じ値を入れて呼び出し側を統一する。
    final maxFileSize = (data['maxFileSize'] as num?)?.toInt();

    return Instance(
      name: data['name'] as String? ?? host,
      description: data['description'] as String?,
      iconUrl: data['iconUrl'] as String?,
      version: data['version'] as String?,
      themeColor: data['themeColor'] as String?,
      contactEmail: data['maintainerEmail'] as String?,
      contactUrl: data['impressumUrl'] as String?,
      rules: rules,
      privacyPolicyUrl: data['privacyPolicyUrl'] as String?,
      statusUrl: data['statusUrl'] as String?,
      imageSizeLimit: maxFileSize,
      videoSizeLimit: maxFileSize,
      audioSizeLimit: maxFileSize,
    );
  }

  @override
  Future<Attachment> uploadAttachment(AttachmentDraft draft) async {
    final file = await client.createDriveFile(
      draft.filePath,
      comment: draft.description,
      mimeType: draft.mimeType,
      isSensitive: draft.sensitive ? true : null,
      folderId: draft.folderId,
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

  // MediaUpdateSupport

  @override
  Future<void> updateAttachmentDescription(
    String mediaId,
    String description, {
    required String postId,
  }) async {
    await client.updateDriveFile(
      mediaId,
      comment: description.isNotEmpty ? description : null,
    );
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
        user: response.user.toCapsicum(host, adminRoleIds: _adminRoleIds),
      );
    } catch (e, s) {
      return LoginFailure(e, s);
    }
  }

  // PinSupport

  @override
  Future<Post> pinPost(String id) async {
    await client.pinNote(id);
    final note = await client.getNote(id);
    return note.toCapsicum(host, pinned: true, adminRoleIds: _adminRoleIds);
  }

  @override
  Future<Post> unpinPost(String id) async {
    await client.unpinNote(id);
    final note = await client.getNote(id);
    return note.toCapsicum(host, pinned: false, adminRoleIds: _adminRoleIds);
  }

  // BookmarkSupport (Misskey の「お気に入り」= Mastodon のブックマーク相当)

  @override
  Future<Post> bookmarkPost(String id) async {
    try {
      await client.favoriteNote(id);
    } on DioException catch (e) {
      // 既にお気に入り済み (ALREADY_FAVORITED) は冪等に成功扱いとする。
      // Misskey はタイムラインにお気に入り状態を返さず事前判定できないため、
      // 長押しメニューからの二重実行で 400 が出るのを握りつぶす (#565)。
      // それ以外の 400 (rate limit 等) は通常どおり surface させる。
      //
      // 注意: mulukhiya 経由のサーバーでは Ginseng::HTTP が上流の 400 を
      // `{error: "Bad response 400"}` にフラット化して code を捨てるため、
      // この判定は一致せず素通りする。その経路は mulukhiya 側で冪等化する
      // (mulukhiya #4380)。本判定は vanilla Misskey 直結時のみ効く。
      if (!_isAlreadyFavorited(e)) rethrow;
    }
    final note = await client.getNote(id);
    return note.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  bool _isAlreadyFavorited(DioException e) {
    if (e.response?.statusCode != 400) return false;
    final data = e.response?.data;
    if (data is Map) {
      final error = data['error'];
      if (error is Map && error['code'] == 'ALREADY_FAVORITED') {
        return true;
      }
    }
    return false;
  }

  @override
  Future<Post> unbookmarkPost(String id) async {
    await client.unfavoriteNote(id);
    final note = await client.getNote(id);
    return note.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  @override
  Future<List<Post>> getBookmarks({TimelineQuery? query}) async {
    final notes = await client.getFavorites(
      untilId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
    );
    return _safeConvert(
      notes,
      (n) => n.toCapsicum(host, adminRoleIds: _adminRoleIds),
      (n) => n.id,
    ).results;
  }

  // AchievementSupport

  @override
  Future<List<Achievement>> getAchievements(String userId) async {
    final items = await client.getUserAchievements(userId);
    return items
        .map(
          (e) => Achievement(
            name: e['name'] as String,
            unlockedAt: DateTime.fromMillisecondsSinceEpoch(
              e['unlockedAt'] as int,
            ),
          ),
        )
        .toList();
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
      return MisskeyUser.fromJson(
        userData,
      ).toCapsicum(client.host, adminRoleIds: _adminRoleIds);
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
      return MisskeyUser.fromJson(
        userData,
      ).toCapsicum(client.host, adminRoleIds: _adminRoleIds);
    }).toList();
    return (users: users, nextCursor: users.lastOrNull?.id);
  }

  /// [type] を渡すと特定の絵文字でリアクションしたユーザーのみを取得する。
  Future<({List<User> users, String? nextCursor})> getReactedBy(
    String noteId, {
    TimelineQuery? query,
    String? type,
  }) async {
    final reactions = await client.getNoteReactions(
      noteId,
      untilId: query?.maxId,
      limit: query?.limit,
      type: type,
    );
    final users = reactions.where((r) => r['user'] is Map<String, dynamic>).map(
      (r) {
        final u = MisskeyUser.fromJson(r['user'] as Map<String, dynamic>);
        return u.toCapsicum(host, adminRoleIds: _adminRoleIds);
      },
    ).toList();
    return (users: users, nextCursor: reactions.lastOrNull?['id'] as String?);
  }

  Future<({List<User> users, String? nextCursor})> getRenotedBy(
    String noteId, {
    TimelineQuery? query,
  }) async {
    final notes = await client.getNoteRenotes(
      noteId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    final users = notes.where((n) => n['user'] is Map<String, dynamic>).map((
      n,
    ) {
      final u = MisskeyUser.fromJson(n['user'] as Map<String, dynamic>);
      return u.toCapsicum(host, adminRoleIds: _adminRoleIds);
    }).toList();
    return (users: users, nextCursor: notes.lastOrNull?['id'] as String?);
  }

  // NotificationSupport

  @override
  Future<NotificationResponse> getNotifications({TimelineQuery? query}) async {
    final notifications = await client.getNotifications(
      sinceId: query?.sinceId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    final converted = _safeConvert(
      notifications,
      (n) => n.toCapsicum(host, adminRoleIds: _adminRoleIds),
      (n) => n.id,
    );
    return NotificationResponse(
      notifications: converted.results,
      rawCount: converted.rawCount,
      rawLastId: converted.rawLastId,
      skippedPosts: converted.skipped,
    );
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
          return SearchResults(
            posts: [note.toCapsicum(host, adminRoleIds: _adminRoleIds)],
          );
        } else if (type == 'User') {
          final user = MisskeyUser.fromJson(
            data['object'] as Map<String, dynamic>,
          );
          return SearchResults(
            users: [user.toCapsicum(host, adminRoleIds: _adminRoleIds)],
          );
        }
      } catch (_) {
        // resolve failed — return empty results.
      }
      return const SearchResults();
    }

    final users = await client.searchUsers(query, limit: 20);
    final hashtags = await client.searchHashtags(query, limit: 20);
    final seen = <String>{};
    return SearchResults(
      users: users
          .map((u) => u.toCapsicum(host, adminRoleIds: _adminRoleIds))
          .where((u) => seen.add(u.id))
          .toList(),
      hashtags: hashtags,
    );
  }

  @override
  Future<List<User>> searchUsers(String query, {int? limit}) async {
    final users = await client.searchUsers(query, limit: limit);
    return users
        .map((u) => u.toCapsicum(host, adminRoleIds: _adminRoleIds))
        .toList();
  }

  @override
  Future<List<String>> searchHashtags(String query, {int? limit}) async {
    return client.searchHashtags(query, limit: limit);
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
            aliases:
                (e['aliases'] as List<dynamic>?)
                    ?.map((a) => a as String)
                    .toList() ??
                const [],
          ),
        )
        .toList();
  }

  @override
  Future<List<String>> getEmojiPalette() async {
    try {
      final data = await client.registryGet('reactions', ['client', 'base']);
      if (data is List) {
        return data.map((e) => e.toString()).toList();
      }
      return const [];
    } catch (_) {
      return const [];
    }
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
    return notes
        .map((n) => n.toCapsicum(host, adminRoleIds: _adminRoleIds))
        .map(_applyWordFilter)
        .toList();
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
    final data = await client.showList(listId);
    final userIds =
        (data['userIds'] as List?)?.cast<String>().toSet().toList() ?? [];
    final users = <User>[];
    for (final userId in userIds) {
      final misskeyUser = await client.showUser(userId);
      users.add(misskeyUser.toCapsicum(host, adminRoleIds: _adminRoleIds));
    }
    return users;
  }

  @override
  Future<void> addListAccounts(String listId, List<String> accountIds) async {
    for (final id in accountIds) {
      await client.pushListUser(listId, id);
    }
  }

  @override
  Future<void> removeListAccounts(
    String listId,
    List<String> accountIds,
  ) async {
    for (final id in accountIds) {
      await client.pullListUser(listId, id);
    }
  }

  // HashtagSupport

  @override
  Future<bool> isFollowingHashtag(String hashtag) => throw UnimplementedError();

  @override
  Future<void> followHashtag(String hashtag) => throw UnimplementedError();

  @override
  Future<void> unfollowHashtag(String hashtag) => throw UnimplementedError();

  @override
  Future<List<Post>> getPostsByHashtag(
    String hashtag, {
    TimelineQuery? query,
    List<String>? all,
  }) async {
    final notes = await client.searchByTag(
      hashtag,
      sinceId: query?.sinceId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    return notes
        .map((n) => n.toCapsicum(host, adminRoleIds: _adminRoleIds))
        .map(_applyWordFilter)
        .toList();
  }

  // ChannelSupport

  @override
  Future<List<Channel>> getFollowedChannels() async {
    final channels = <Channel>[];
    String? untilId;
    const pageSize = 100;

    while (true) {
      final data = await client.getFollowedChannels(
        limit: pageSize,
        untilId: untilId,
      );
      channels.addAll(
        data.map(
          (ch) => Channel(
            id: ch['id'] as String,
            name: ch['name'] as String? ?? '',
          ),
        ),
      );
      if (data.length < pageSize) break;
      untilId = data.last['id'] as String;
    }

    return channels;
  }

  @override
  Future<List<Post>> getChannelTimeline(
    String channelId, {
    TimelineQuery? query,
  }) async {
    final notes = await client.getChannelTimeline(
      channelId,
      sinceId: query?.sinceId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    return notes
        .map((n) => n.toCapsicum(host, adminRoleIds: _adminRoleIds))
        .map(_applyWordFilter)
        .toList();
  }

  // FlashSupport

  @override
  Future<List<Flash>> getFeaturedFlashes() async {
    final data = await client.getFeaturedFlashes();
    return data
        .map(
          (f) => Flash(
            id: f['id'] as String,
            title: f['title'] as String? ?? '',
            summary: f['summary'] as String?,
            userName:
                (f['user'] as Map<String, dynamic>?)?['username'] as String?,
          ),
        )
        .toList();
  }

  // GallerySupport

  GalleryPost _mapGalleryPost(Map<String, dynamic> g) {
    final user = MisskeyUser.fromJson(g['user'] as Map<String, dynamic>);
    final files = (g['files'] as List? ?? [])
        .map((f) => MisskeyDriveFile.fromJson(f as Map<String, dynamic>))
        .map((f) => f.toCapsicum())
        .toList();
    return GalleryPost(
      id: g['id'] as String,
      title: g['title'] as String? ?? '',
      description: g['description'] as String?,
      author: user.toCapsicum(host, adminRoleIds: _adminRoleIds),
      files: files,
      createdAt: DateTime.parse(
        g['createdAt'] as String? ?? '1970-01-01T00:00:00Z',
      ),
      isSensitive: g['isSensitive'] as bool? ?? false,
      likedCount: g['likedCount'] as int? ?? 0,
    );
  }

  @override
  Future<List<GalleryPost>> getGalleryPosts({TimelineQuery? query}) async {
    final data = await client.getGalleryFeatured(
      sinceId: query?.sinceId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    return data.map(_mapGalleryPost).toList();
  }

  @override
  Future<List<GalleryPost>> getUserGalleryPosts(
    String userId, {
    TimelineQuery? query,
  }) async {
    final data = await client.getUserGalleryPosts(
      userId,
      sinceId: query?.sinceId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    return data.map(_mapGalleryPost).toList();
  }

  // PagesSupport (#186)

  Page _mapPage(Map<String, dynamic> p) {
    final user = MisskeyUser.fromJson(p['user'] as Map<String, dynamic>);
    final eyeCatching = p['eyeCatchingImage'] as Map<String, dynamic>?;
    final eyeCatchingAttachment = eyeCatching == null
        ? null
        : MisskeyDriveFile.fromJson(eyeCatching).toCapsicum();
    // pages/show のレスポンスに含まれる attachedFiles を fileId→Attachment
    // で索引化する。ブロックレンダラが image ブロックの fileId で引く。
    // users/pages では空のことがあるが、ページ詳細表示 (getPageById /
    // getPageByName) で必要十分。
    final attachedFiles = <String, Attachment>{};
    for (final raw in (p['attachedFiles'] as List? ?? const [])) {
      if (raw is! Map<String, dynamic>) continue;
      final file = MisskeyDriveFile.fromJson(raw).toCapsicum();
      attachedFiles[file.id] = file;
    }
    return Page(
      id: p['id'] as String,
      name: p['name'] as String? ?? '',
      title: p['title'] as String? ?? '',
      summary: p['summary'] as String?,
      content: ((p['content'] as List?) ?? const [])
          .cast<Map<String, dynamic>>(),
      author: user.toCapsicum(host, adminRoleIds: _adminRoleIds),
      createdAt: DateTime.parse(
        p['createdAt'] as String? ?? '1970-01-01T00:00:00Z',
      ),
      updatedAt: DateTime.parse(
        p['updatedAt'] as String? ??
            p['createdAt'] as String? ??
            '1970-01-01T00:00:00Z',
      ),
      eyeCatchingImage: eyeCatchingAttachment,
      attachedFiles: attachedFiles,
      likedCount: p['likedCount'] as int? ?? 0,
      isLiked: p['isLiked'] as bool? ?? false,
    );
  }

  @override
  Future<List<Page>> getUserPages(String userId, {TimelineQuery? query}) async {
    final data = await client.getUserPages(
      userId,
      sinceId: query?.sinceId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    return data.map(_mapPage).toList();
  }

  @override
  Future<Page> getPageById(String pageId) async {
    final data = await client.getPageById(pageId);
    return _mapPage(data);
  }

  @override
  Future<Page> getPageByName({
    required String username,
    required String name,
  }) async {
    final data = await client.getPageByName(username: username, name: name);
    return _mapPage(data);
  }

  @override
  Future<List<Page>> getFeaturedPages({TimelineQuery? query}) async {
    final data = await client.getFeaturedPages(limit: query?.limit);
    return data.map(_mapPage).toList();
  }

  @override
  Future<List<LikedPageEntry>> getLikedPages({TimelineQuery? query}) async {
    final data = await client.getMyPageLikes(
      sinceId: query?.sinceId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    // /api/i/page-likes は {id, page} の配列を返す。`id` はライクエントリ
    // 自体の ID で、pagination cursor として渡すべきはこちら (#631)。
    final entries = <LikedPageEntry>[];
    for (final e in data) {
      final likeId = e['id'] as String?;
      final pageMap = e['page'] as Map<String, dynamic>?;
      if (likeId == null || pageMap == null) continue;
      entries.add((likeId: likeId, page: _mapPage(pageMap)));
    }
    return entries;
  }

  @override
  Future<void> likePage(String pageId) => client.likePage(pageId);

  @override
  Future<void> unlikePage(String pageId) => client.unlikePage(pageId);

  // DriveSupport

  @override
  Future<List<Attachment>> getDriveFiles({
    String? folderId,
    TimelineQuery? query,
  }) async {
    final files = await client.getDriveFiles(
      folderId: folderId,
      sinceId: query?.sinceId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    return files.map((f) => f.toCapsicum()).toList();
  }

  @override
  Future<List<DriveFolder>> getDriveFolders({
    String? folderId,
    TimelineQuery? query,
  }) async {
    final data = await client.getDriveFolders(
      folderId: folderId,
      sinceId: query?.sinceId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    return data
        .map(
          (f) => DriveFolder(
            id: f['id'] as String,
            name: f['name'] as String? ?? '',
            parentId: f['parentId'] as String?,
          ),
        )
        .toList();
  }

  @override
  Future<void> deleteDriveFile(String fileId) async {
    await client.deleteDriveFile(fileId);
  }

  @override
  Future<void> renameDriveFile(String fileId, String newName) async {
    await client.updateDriveFile(fileId, name: newName);
  }

  @override
  Future<void> moveDriveFile(String fileId, String? folderId) async {
    // Misskey API ではキー省略=変更なし、明示的 null=ルートへ移動。
    // updateDriveFile は null-aware で省略するため、直接 POST する。
    await client.dio.post(
      '/api/drive/files/update',
      data: client.createBody({'fileId': fileId, 'folderId': folderId}),
    );
  }

  @override
  Future<DriveFolder> createDriveFolder(String name, {String? parentId}) async {
    final data = await client.createDriveFolder(name, parentId: parentId);
    return DriveFolder(
      id: data['id'] as String,
      name: data['name'] as String? ?? '',
      parentId: data['parentId'] as String?,
    );
  }

  @override
  Future<void> deleteDriveFolder(String folderId) async {
    await client.deleteDriveFolder(folderId);
  }

  @override
  Future<void> renameDriveFolder(String folderId, String newName) async {
    await client.updateDriveFolder(folderId, name: newName);
  }

  @override
  Future<void> moveDriveFolder(String folderId, String? parentId) async {
    // Misskey API はキー省略=変更なし、明示的 null=ルートへ移動。
    // updateDriveFolder は null-aware で省略するため、直接 POST する。
    //
    // 単階層前提: caller (drive_manager_screen._promptMoveFolder) は現在
    // 開いているフォルダの直下の子だけを候補に出し、folderId 自身と祖先は
    // 候補から除外しているため、ここで循環防止のサーバーチェック (Misskey
    // は子孫を parentId に渡すと 400/422) を踏まないことを前提にしている。
    // 将来 candidate に親フォルダや遠縁を含めるなら、Misskey の error
    // ハンドリング (DioException response) を caller 側で吸収すること。
    await client.dio.post(
      '/api/drive/folders/update',
      data: client.createBody({'folderId': folderId, 'parentId': parentId}),
    );
  }

  // AntennaSupport

  @override
  Future<List<Antenna>> getAntennas() async {
    final data = await client.getAntennas();
    return data
        .map(
          (a) =>
              Antenna(id: a['id'] as String, name: a['name'] as String? ?? ''),
        )
        .toList();
  }

  @override
  Future<List<Post>> getAntennaNotes(
    String antennaId, {
    TimelineQuery? query,
  }) async {
    final notes = await client.getAntennaNotes(
      antennaId,
      sinceId: query?.sinceId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    return notes
        .map((n) => n.toCapsicum(host, adminRoleIds: _adminRoleIds))
        .map(_applyWordFilter)
        .toList();
  }

  // ClipSupport

  @override
  Future<List<NoteClip>> getClips() async {
    final data = await client.getClips();
    return data
        .map(
          (c) => NoteClip(
            id: c['id'] as String,
            name: c['name'] as String? ?? '',
            description: c['description'] as String?,
          ),
        )
        .toList();
  }

  @override
  Future<List<Post>> getClipNotes(String clipId, {TimelineQuery? query}) async {
    final notes = await client.getClipNotes(
      clipId,
      sinceId: query?.sinceId,
      untilId: query?.maxId,
      limit: query?.limit,
    );
    return notes
        .map((n) => n.toCapsicum(host, adminRoleIds: _adminRoleIds))
        .map(_applyWordFilter)
        .toList();
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
  Stream<Post> streamTimeline(
    TimelineType type, {
    void Function(Object error, StackTrace stack)? onParseError,
    void Function(Object error, StackTrace stack)? onStreamError,
    void Function()? onReconnectExhausted,
    void Function(StreamConnectionState state)? onConnectionState,
    void Function(int? closeCode, String? closeReason)? onDisconnect,
  }) {
    _streaming?.dispose();
    final token = client.accessToken;
    if (token == null) return const Stream.empty();
    _streaming = MisskeyStreaming(
      host: host,
      accessToken: token,
      adminRoleIds: _adminRoleIds,
      onParseError: onParseError,
      onStreamError: onStreamError,
      onReconnectExhausted: onReconnectExhausted,
      onConnectionState: onConnectionState,
      onDisconnect: onDisconnect,
    );
    return _streaming!.connect(type).map(_applyWordFilter);
  }

  @override
  void disposeStream() {
    _streaming?.dispose();
    _streaming = null;
  }

  // NotificationStreamSupport (#569)

  @override
  Stream<Notification> streamNotifications({
    void Function(Object error, StackTrace stack)? onParseError,
    void Function(Object error, StackTrace stack)? onStreamError,
    void Function()? onReconnectExhausted,
  }) {
    _notificationStreaming?.dispose();
    final token = client.accessToken;
    if (token == null) return const Stream.empty();
    _notificationStreaming = MisskeyNotificationStreaming(
      host: host,
      accessToken: token,
      adminRoleIds: _adminRoleIds,
      onParseError: onParseError,
      onStreamError: onStreamError,
      onReconnectExhausted: onReconnectExhausted,
    );
    return _notificationStreaming!.connect();
  }

  @override
  void disposeNotificationStream() {
    _notificationStreaming?.dispose();
    _notificationStreaming = null;
  }

  // URL preview

  Future<PreviewCard?> fetchUrlPreview(String url) async {
    try {
      final data = await client.getUrlPreview(url);
      final title = data['title'] as String?;
      final description = data['description'] as String?;
      final imageUrl = data['thumbnail'] as String?;
      if (title == null || title.isEmpty) return null;
      // タイトルのみで thumbnail も description もない場合はプレビュー不可とみなす
      if (imageUrl == null && (description == null || description.isEmpty)) {
        return null;
      }
      return PreviewCard(
        url: url,
        title: title,
        description: description,
        imageUrl: imageUrl,
      );
    } catch (_) {
      return null;
    }
  }

  // ProfileEditSupport

  @override
  Future<int?> getMaxProfileFields() async => null;

  @override
  Future<User> updateProfile({
    String? displayName,
    String? description,
    String? avatarFilePath,
    String? bannerFilePath,
    List<UserField>? fields,
  }) async {
    String? avatarId;
    String? bannerId;
    if (avatarFilePath != null) {
      final file = await client.createDriveFile(avatarFilePath);
      avatarId = file['id'] as String;
    }
    if (bannerFilePath != null) {
      final file = await client.createDriveFile(bannerFilePath);
      bannerId = file['id'] as String;
    }
    final mappedFields = fields
        ?.where((f) => f.name.isNotEmpty || f.value.isNotEmpty)
        .map((f) => {'name': f.name, 'value': f.value})
        .toList();
    final user = await client.updateI(
      name: displayName != null
          ? (displayName.isEmpty ? '' : displayName)
          : null,
      description: description,
      avatarId: avatarId,
      bannerId: bannerId,
      fields: mappedFields?.isNotEmpty == true ? mappedFields : null,
    );
    return user.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  // ReportSupport

  @override
  Future<void> reportPost(
    String postId,
    String authorId, {
    String? comment,
  }) async {
    await client.reportAbuse(authorId, comment: comment ?? '投稿 $postId に対する通報');
  }

  // TranslationSupport

  @override
  Future<TranslationResult> translatePost(
    String postId, {
    String? targetLang,
  }) async {
    final data = await client.translateNote(
      postId,
      targetLang: targetLang ?? 'ja',
    );
    return TranslationResult(
      content: data['text'] as String? ?? '',
      detectedLanguage: data['sourceLang'] as String?,
    );
  }

  // -- PushSubscriptionSupport --

  @override
  Future<String?> getVapidPublicKey() async {
    try {
      final data = await client.getMeta();
      return data['swPublickey'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>> subscribePush({
    required String endpoint,
    required String p256dh,
    required String auth,
  }) async {
    try {
      return await client.subscribePush(
        endpoint: endpoint,
        publickey: p256dh,
        auth: auth,
      );
    } on DioException catch (e) {
      // Misskey upstream は /api/sw/register を `secure: true` で制限しており
      // （GHSA-7pxq-6xx9-xpgm, 2023-12）、サードパーティアプリのアクセストークン
      // では HTTP 400 + `{error: {code: 'ACCESS_DENIED'}}` を返す。再試行しても
      // 成功しない既知の仕様制約。Misskey フォークによっては `/api/sw/register`
      // 自体を削除している場合 (404) や、別形状の 400 を返す場合もあるため、
      // /api/sw/register に対する 400 / 404 はすべて非対応扱いに寄せる (#365)。
      if (_isUnsupportedRegistration(e)) {
        throw PushRegistrationNotSupportedException(
          'Misskey upstream blocks third-party Web Push registration '
          '(/api/sw/register requires secure session; see GHSA-7pxq-6xx9-xpgm)',
        );
      }
      rethrow;
    }
  }

  bool _isUnsupportedRegistration(DioException e) {
    final status = e.response?.statusCode;
    return status == 400 || status == 404;
  }

  @override
  Future<void> unsubscribePush({String? endpoint}) async {
    if (endpoint == null) return;
    await client.unsubscribePush(endpoint: endpoint);
  }

  // -- ChatSupport --

  // readonly ロールでも履歴閲覧は試させる方針 (#446)。実際の 403 は UI 側
  // で error builder が処理する。
  @override
  bool get canReadChat => true;

  @override
  bool get canWriteChat => _canWriteChat;

  Future<User> _ensureMyUser() async {
    final cached = _myUser;
    if (cached != null) return cached;
    return getMyself();
  }

  @override
  Future<List<ChatThread>> getChatHistory({TimelineQuery? query}) async {
    final me = await _ensureMyUser();
    // /api/chat/history はサーバー側ページング非対応 (#445)。query.maxId は
    // 無視し、limit のみ通す。
    final entries = await client.getChatHistory(limit: query?.limit);
    return entries
        .map(
          (e) => misskeyChatThreadFromHistoryEntry(
            e,
            host,
            me.id,
            adminRoleIds: _adminRoleIds,
          ),
        )
        .toList();
  }

  @override
  Future<List<ChatMessage>> getUserMessages({
    required String userId,
    TimelineQuery? query,
  }) async {
    final me = await _ensureMyUser();
    // user-timeline は fromUser / toUser オブジェクトを省略するレスポンスを
    // 返すことがあるため、self と counterparty を事前解決して helper に
    // フォールバックとして渡す。
    final counterparty = await getUserById(userId);
    final messages = await client.getChatUserMessages(
      userId: userId,
      untilId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
    );
    return messages
        .map(
          (m) => misskeyChatMessageFromMap(
            m,
            host,
            adminRoleIds: _adminRoleIds,
            selfUser: me,
            counterpartyUser: counterparty,
            // user-timeline は呼び出し時点で既読更新されるため、isRead を
            // 持たない lite スキーマでは既読扱いに倒す (#447)。
            defaultIsRead: true,
          ),
        )
        .toList();
  }

  @override
  Future<ChatMessage> sendUserMessage({
    required String userId,
    String? text,
    String? fileId,
  }) async {
    final me = await _ensureMyUser();
    final counterparty = await getUserById(userId);
    final data = await client.createChatMessageToUser(
      toUserId: userId,
      text: text,
      fileId: fileId,
    );
    return misskeyChatMessageFromMap(
      data,
      host,
      adminRoleIds: _adminRoleIds,
      selfUser: me,
      counterpartyUser: counterparty,
      // create のレスポンス (ChatMessageLiteFor1on1) には `isRead` が無く、
      // 自分が送ったメッセージなので未読扱いにすると自前未読バッジに乗る。
      defaultIsRead: true,
    );
  }

  @override
  Future<void> deleteChatMessage(String messageId) async {
    await client.deleteChatMessage(messageId);
  }

  @override
  Future<void> reactToChatMessage({
    required String messageId,
    required String reaction,
  }) => client.reactToChatMessage(messageId: messageId, reaction: reaction);

  @override
  Future<void> unreactToChatMessage({
    required String messageId,
    required String reaction,
  }) => client.unreactToChatMessage(messageId: messageId, reaction: reaction);

  @override
  Stream<ChatMessage> streamChatMessages({
    void Function(Object error, StackTrace stack)? onParseError,
    void Function(Object error, StackTrace stack)? onStreamError,
    void Function()? onReconnectExhausted,
  }) {
    _chatStreaming?.dispose();
    final token = client.accessToken;
    if (token == null) return const Stream.empty();
    _chatStreaming = MisskeyChatStreaming(
      host: host,
      accessToken: token,
      adminRoleIds: _adminRoleIds,
      selfUser: _myUser,
      onParseError: onParseError,
      onStreamError: onStreamError,
      onReconnectExhausted: onReconnectExhausted,
    );
    return _chatStreaming!.connect();
  }

  @override
  void disposeChatStream() {
    _chatStreaming?.dispose();
    _chatStreaming = null;
  }

  @override
  Future<void> markAllChatRead() async {
    await client.markAllChatRead();
  }

  // -- ChatSupport (rooms, #438) ---------------------------------------------

  @override
  Future<List<ChatThread>> getRoomHistory({TimelineQuery? query}) async {
    final me = await _ensureMyUser();
    // /api/chat/history はサーバー側ページング非対応 (#445)。query.maxId は
    // 無視し、limit のみ通す。room: true でルーム履歴を取得。
    final entries = await client.getChatHistory(
      limit: query?.limit,
      room: true,
    );
    return entries
        .map(
          (e) => misskeyChatThreadFromHistoryEntry(
            e,
            host,
            me.id,
            adminRoleIds: _adminRoleIds,
          ),
        )
        .toList();
  }

  @override
  Future<List<ChatRoom>> getJoiningRooms({TimelineQuery? query}) async {
    // /joining は ChatRoomMembership を返し、room が populate されている。
    // 呼び出し側はルーム本体を欲しているので unwrap する。
    final memberships = await client.getJoiningChatRooms(
      untilId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
    );
    return memberships
        .map(
          (m) => misskeyChatRoomMemberFromMap(
            m,
            host,
            adminRoleIds: _adminRoleIds,
          ),
        )
        .whereType<ChatRoomMember>()
        .map((m) => m.room)
        .whereType<ChatRoom>()
        .toList();
  }

  @override
  Future<List<ChatRoom>> getOwnedRooms({TimelineQuery? query}) async {
    final rooms = await client.getOwnedChatRooms(
      untilId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
    );
    return rooms
        .map(
          (r) => misskeyChatRoomFromMap(r, host, adminRoleIds: _adminRoleIds),
        )
        .whereType<ChatRoom>()
        .toList();
  }

  @override
  Future<ChatRoom> getRoom(String roomId) async {
    final data = await client.getChatRoom(roomId);
    final room = misskeyChatRoomFromMap(
      data,
      host,
      adminRoleIds: _adminRoleIds,
    );
    if (room == null) {
      throw const FormatException(
        'Misskey chat room response missing required fields',
      );
    }
    return room;
  }

  @override
  Future<ChatRoom> createRoom({
    required String name,
    String? description,
  }) async {
    final data = await client.createChatRoom(
      name: name,
      description: description,
    );
    final room = misskeyChatRoomFromMap(
      data,
      host,
      adminRoleIds: _adminRoleIds,
    );
    if (room == null) {
      throw const FormatException(
        'Misskey chat room create response missing required fields',
      );
    }
    return room;
  }

  @override
  Future<ChatRoom> updateRoom({
    required String roomId,
    String? name,
    String? description,
  }) async {
    final data = await client.updateChatRoom(
      roomId: roomId,
      name: name,
      description: description,
    );
    final room = misskeyChatRoomFromMap(
      data,
      host,
      adminRoleIds: _adminRoleIds,
    );
    if (room == null) {
      throw const FormatException(
        'Misskey chat room update response missing required fields',
      );
    }
    return room;
  }

  @override
  Future<void> deleteRoom(String roomId) async {
    await client.deleteChatRoom(roomId);
  }

  @override
  Future<void> joinRoom(String roomId) async {
    await client.joinChatRoom(roomId);
  }

  @override
  Future<void> leaveRoom(String roomId) async {
    await client.leaveChatRoom(roomId);
  }

  @override
  Future<List<ChatRoomMember>> getRoomMembers({
    required String roomId,
    TimelineQuery? query,
  }) async {
    final members = await client.getChatRoomMembers(
      roomId: roomId,
      untilId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
    );
    return members
        .map(
          (m) => misskeyChatRoomMemberFromMap(
            m,
            host,
            adminRoleIds: _adminRoleIds,
          ),
        )
        .whereType<ChatRoomMember>()
        .toList();
  }

  @override
  Future<List<ChatMessage>> getRoomMessages({
    required String roomId,
    TimelineQuery? query,
  }) async {
    final me = await _ensureMyUser();
    final messages = await client.getChatRoomMessages(
      roomId: roomId,
      untilId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
    );
    return messages
        .map(
          (m) => misskeyChatMessageFromMap(
            m,
            host,
            adminRoleIds: _adminRoleIds,
            selfUser: me,
            // room-timeline はサーバー側で既読更新済み (room-timeline.ts
            // readRoomChatMessage)。isRead を持たない lite スキーマ
            // (`ChatMessageLiteForRoom`) なので true に倒す (DM の
            // user-timeline と同方針 #447)。
            defaultIsRead: true,
          ),
        )
        .toList();
  }

  @override
  Future<ChatMessage> sendRoomMessage({
    required String roomId,
    String? text,
    String? fileId,
  }) async {
    final me = await _ensureMyUser();
    final data = await client.createChatMessageToRoom(
      toRoomId: roomId,
      text: text,
      fileId: fileId,
    );
    return misskeyChatMessageFromMap(
      data,
      host,
      adminRoleIds: _adminRoleIds,
      selfUser: me,
      // create のレスポンス (ChatMessageLiteForRoom) には `isRead` が無く、
      // 自分が送ったメッセージなので未読扱いにすると自前未読バッジに乗る。
      defaultIsRead: true,
    );
  }

  @override
  Future<void> setRoomMute({required String roomId, required bool mute}) async {
    await client.setChatRoomMute(roomId: roomId, mute: mute);
  }

  @override
  Future<void> inviteToRoom({
    required String roomId,
    required String userId,
  }) async {
    await client.createChatRoomInvitation(roomId: roomId, userId: userId);
  }

  @override
  Future<void> ignoreInvitation(String roomId) async {
    await client.ignoreChatRoomInvitation(roomId);
  }

  @override
  Future<List<ChatRoomInvitation>> getInvitationInbox({
    TimelineQuery? query,
  }) async {
    final invitations = await client.getChatRoomInvitationInbox(
      untilId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
    );
    return invitations
        .map(
          (i) => misskeyChatRoomInvitationFromMap(
            i,
            host,
            adminRoleIds: _adminRoleIds,
          ),
        )
        .whereType<ChatRoomInvitation>()
        .toList();
  }

  @override
  Future<List<ChatRoomInvitation>> getInvitationOutbox({
    TimelineQuery? query,
  }) async {
    final invitations = await client.getChatRoomInvitationOutbox(
      untilId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
    );
    return invitations
        .map(
          (i) => misskeyChatRoomInvitationFromMap(
            i,
            host,
            adminRoleIds: _adminRoleIds,
          ),
        )
        .whereType<ChatRoomInvitation>()
        .toList();
  }

  @override
  Stream<ChatMessage> streamRoomMessages({
    required String roomId,
    void Function(Object error, StackTrace stack)? onParseError,
    void Function(Object error, StackTrace stack)? onStreamError,
    void Function()? onReconnectExhausted,
  }) {
    _chatRoomStreamings.remove(roomId)?.dispose();
    final token = client.accessToken;
    if (token == null) return const Stream.empty();
    final streaming = MisskeyChatRoomStreaming(
      host: host,
      accessToken: token,
      roomId: roomId,
      adminRoleIds: _adminRoleIds,
      selfUser: _myUser,
      onParseError: onParseError,
      onStreamError: onStreamError,
      onReconnectExhausted: onReconnectExhausted,
    );
    _chatRoomStreamings[roomId] = streaming;
    return streaming.connect();
  }

  @override
  void disposeRoomChatStream({String? roomId}) {
    if (roomId == null) {
      for (final s in _chatRoomStreamings.values) {
        s.dispose();
      }
      _chatRoomStreamings.clear();
      return;
    }
    _chatRoomStreamings.remove(roomId)?.dispose();
  }
}

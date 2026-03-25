import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:http_parser/http_parser.dart';

import '../rate_limit_interceptor.dart';

class MisskeyClient {
  final Dio dio;
  final String host;
  String? _token;

  MisskeyClient(this.host) : dio = Dio(BaseOptions(baseUrl: 'https://$host')) {
    dio.interceptors.add(RateLimitInterceptor(dio));
  }

  String? get accessToken => _token;

  void setAccessToken(String token) {
    _token = token;
  }

  /// Misskey API requests are POST with `i` token in the JSON body.
  Map<String, dynamic> createBody([Map<String, dynamic>? params]) {
    return {if (_token != null) 'i': _token, ...?params};
  }

  /// POST /api/miauth/{session}/check
  Future<MisskeyCheckSessionResponse> checkSession(String session) async {
    final response = await dio.post(
      '/api/miauth/$session/check',
      data: createBody(),
    );
    return MisskeyCheckSessionResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// POST /api/i
  Future<MisskeyUser> getI() async {
    final response = await dio.post('/api/i', data: createBody());
    return MisskeyUser.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/users/show
  Future<MisskeyUser> showUser(String userId) async {
    final response = await dio.post(
      '/api/users/show',
      data: createBody({'userId': userId}),
    );
    return MisskeyUser.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/users/show (by username)
  Future<MisskeyUser?> showUserByName(
    String username, [
    String? remoteHost,
  ]) async {
    try {
      final response = await dio.post(
        '/api/users/show',
        data: createBody({'username': username, 'host': ?remoteHost}),
      );
      return MisskeyUser.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// POST /api/users/notes
  Future<List<MisskeyNote>> getUserNotes(
    String userId, {
    String? untilId,
    int? limit,
    bool? pinned,
    bool? withFiles,
  }) async {
    final response = await dio.post(
      '/api/users/notes',
      data: createBody({
        'userId': userId,
        'untilId': ?untilId,
        'limit': ?limit,
        'pinned': ?pinned,
        'withFiles': ?withFiles,
      }),
    );
    return (response.data as List)
        .map((e) => MisskeyNote.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/users/followers
  Future<List<Map<String, dynamic>>> getUserFollowers(
    String userId, {
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/users/followers',
      data: createBody({
        'userId': userId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/users/following
  Future<List<Map<String, dynamic>>> getUserFollowing(
    String userId, {
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/users/following',
      data: createBody({
        'userId': userId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/users/relation
  Future<Map<String, dynamic>> getUserRelation(String userId) async {
    final response = await dio.post(
      '/api/users/relation',
      data: createBody({'userId': userId}),
    );
    final data = response.data;
    // API returns a single object for single userId, or an array for multiple.
    if (data is List) {
      return data.first as Map<String, dynamic>;
    }
    return data as Map<String, dynamic>;
  }

  /// POST /api/following/create
  Future<void> followUser(String userId) async {
    await dio.post(
      '/api/following/create',
      data: createBody({'userId': userId}),
    );
  }

  /// POST /api/following/delete
  Future<void> unfollowUser(String userId) async {
    await dio.post(
      '/api/following/delete',
      data: createBody({'userId': userId}),
    );
  }

  /// POST /api/mute/create
  Future<void> muteUser(String userId, {int? expiresAt}) async {
    await dio.post(
      '/api/mute/create',
      data: createBody({'userId': userId, 'expiresAt': ?expiresAt}),
    );
  }

  /// POST /api/mute/delete
  Future<void> unmuteUser(String userId) async {
    await dio.post('/api/mute/delete', data: createBody({'userId': userId}));
  }

  /// POST /api/blocking/create
  Future<void> blockUser(String userId) async {
    await dio.post(
      '/api/blocking/create',
      data: createBody({'userId': userId}),
    );
  }

  /// POST /api/blocking/delete
  Future<void> unblockUser(String userId) async {
    await dio.post(
      '/api/blocking/delete',
      data: createBody({'userId': userId}),
    );
  }

  /// POST /api/notes/timeline (home)
  Future<List<MisskeyNote>> getTimeline({
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/notes/timeline',
      data: createBody({
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List)
        .map((e) => MisskeyNote.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/drive/files/create
  Future<Map<String, dynamic>> createDriveFile(
    String filePath, {
    String? comment,
    String? mimeType,
    bool? isSensitive,
  }) async {
    final fileName = filePath.split('/').last;
    final mediaType = mimeType != null ? MediaType.parse(mimeType) : null;

    Future<FormData> buildFormData() async => FormData.fromMap({
      'file': await MultipartFile.fromFile(
        filePath,
        filename: fileName,
        contentType: mediaType,
      ),
      'comment': ?comment,
      'isSensitive': ?isSensitive,
      if (_token != null) 'i': _token,
    });

    final formData = await buildFormData();
    final response = await dio.post(
      '/api/drive/files/create',
      data: formData,
      options: Options(
        extra: {RateLimitInterceptor.formDataFactoryKey: buildFormData},
      ),
    );
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/drive/files/update
  Future<MisskeyDriveFile> updateDriveFile(
    String fileId, {
    String? comment,
  }) async {
    final response = await dio.post(
      '/api/drive/files/update',
      data: createBody({'fileId': fileId, 'comment': comment}),
    );
    return MisskeyDriveFile.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/notes/create
  Future<MisskeyNote> createNote({
    required String text,
    required String visibility,
    String? replyId,
    String? renoteId,
    List<String>? fileIds,
    String? cw,
    bool? localOnly,
    String? channelId,
    Map<String, String>? extraHeaders,
  }) async {
    final response = await dio.post(
      '/api/notes/create',
      data: createBody({
        'text': text,
        'visibility': visibility,
        'replyId': ?replyId,
        'renoteId': ?renoteId,
        'fileIds': ?fileIds,
        'cw': ?cw,
        'localOnly': ?localOnly,
        'channelId': ?channelId,
      }),
      options: extraHeaders != null ? Options(headers: extraHeaders) : null,
    );
    return MisskeyNote.fromJson(
      (response.data as Map<String, dynamic>)['createdNote']
          as Map<String, dynamic>,
    );
  }

  /// POST /api/notes/drafts/create — create a scheduled note.
  Future<void> createScheduledNote({
    required String text,
    required String visibility,
    required DateTime scheduledAt,
    String? replyId,
    String? renoteId,
    List<String>? fileIds,
    String? cw,
    bool? localOnly,
    String? channelId,
  }) async {
    await dio.post(
      '/api/notes/drafts/create',
      data: createBody({
        'text': text,
        'visibility': visibility,
        'scheduledAt': scheduledAt.toUtc().millisecondsSinceEpoch,
        'isActuallyScheduled': true,
        'replyId': ?replyId,
        'renoteId': ?renoteId,
        'fileIds': ?fileIds,
        'cw': ?cw,
        'localOnly': ?localOnly,
        'channelId': ?channelId,
      }),
    );
  }

  /// POST /api/notes/drafts/list — list scheduled notes.
  Future<List<ScheduledPost>> getScheduledNotes() async {
    final response = await dio.post(
      '/api/notes/drafts/list',
      data: createBody({'scheduled': true}),
    );
    return (response.data as List).map((e) {
      final json = e as Map<String, dynamic>;
      return ScheduledPost(
        id: json['id'] as String,
        scheduledAt: DateTime.fromMillisecondsSinceEpoch(
          json['scheduledAt'] as int,
          isUtc: true,
        ),
        content: json['text'] as String?,
        spoilerText: json['cw'] as String?,
        visibility: json['visibility'] as String?,
        mediaIds:
            (json['fileIds'] as List?)?.map((id) => id as String).toList() ??
            [],
      );
    }).toList();
  }

  /// POST /api/notes/drafts/delete — cancel a scheduled note.
  Future<void> deleteScheduledNote(String id) async {
    await dio.post(
      '/api/notes/drafts/delete',
      data: createBody({'draftId': id}),
    );
  }

  /// POST /api/users/report-abuse
  Future<void> reportAbuse(String userId, {required String comment}) async {
    await dio.post(
      '/api/users/report-abuse',
      data: createBody({'userId': userId, 'comment': comment}),
    );
  }

  /// POST /api/notes/delete
  Future<void> deleteNote(String noteId) async {
    await dio.post('/api/notes/delete', data: createBody({'noteId': noteId}));
  }

  /// POST /api/notes/show
  Future<MisskeyNote> getNote(String noteId) async {
    final response = await dio.post(
      '/api/notes/show',
      data: createBody({'noteId': noteId}),
    );
    return MisskeyNote.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/notes/children
  Future<List<MisskeyNote>> getNoteChildren({
    required String noteId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/notes/children',
      data: createBody({'noteId': noteId, 'limit': ?limit}),
    );
    return (response.data as List)
        .map((e) => MisskeyNote.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/i/pin
  Future<void> pinNote(String noteId) async {
    await dio.post('/api/i/pin', data: createBody({'noteId': noteId}));
  }

  /// POST /api/i/unpin
  Future<void> unpinNote(String noteId) async {
    await dio.post('/api/i/unpin', data: createBody({'noteId': noteId}));
  }

  /// POST /api/notes/reactions
  Future<List<Map<String, dynamic>>> getNoteReactions(
    String noteId, {
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/notes/reactions',
      data: createBody({
        'noteId': noteId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/notes/renotes
  Future<List<Map<String, dynamic>>> getNoteRenotes(
    String noteId, {
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/notes/renotes',
      data: createBody({
        'noteId': noteId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/notes/favorites/create
  Future<void> favoriteNote(String noteId) async {
    await dio.post(
      '/api/notes/favorites/create',
      data: createBody({'noteId': noteId}),
    );
  }

  /// POST /api/notes/favorites/delete
  Future<void> unfavoriteNote(String noteId) async {
    await dio.post(
      '/api/notes/favorites/delete',
      data: createBody({'noteId': noteId}),
    );
  }

  /// POST /api/i/favorites
  Future<List<MisskeyNote>> getFavorites({
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/i/favorites',
      data: createBody({
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List)
        .map(
          (e) => MisskeyNote.fromJson(
            (e as Map<String, dynamic>)['note'] as Map<String, dynamic>,
          ),
        )
        .toList();
  }

  /// POST /api/announcements
  Future<List<MisskeyAnnouncement>> getAnnouncements({int? limit}) async {
    final response = await dio.post(
      '/api/announcements',
      data: createBody({'limit': ?limit}),
    );
    return (response.data as List)
        .map((e) => MisskeyAnnouncement.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/i/read-announcement
  Future<void> readAnnouncement(String announcementId) async {
    await dio.post(
      '/api/i/read-announcement',
      data: createBody({'announcementId': announcementId}),
    );
  }

  /// POST /api/notes/create (renote)
  Future<MisskeyNote> renote(String noteId) async {
    final response = await dio.post(
      '/api/notes/create',
      data: createBody({'renoteId': noteId}),
    );
    return MisskeyNote.fromJson(
      (response.data as Map<String, dynamic>)['createdNote']
          as Map<String, dynamic>,
    );
  }

  /// POST /api/i/notifications
  Future<List<MisskeyNotification>> getNotifications({
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/i/notifications',
      data: createBody({
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List)
        .map((e) => MisskeyNotification.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/notes/reactions/create
  Future<void> createReaction(String noteId, String reaction) async {
    await dio.post(
      '/api/notes/reactions/create',
      data: createBody({'noteId': noteId, 'reaction': reaction}),
    );
  }

  /// POST /api/notes/reactions/delete
  Future<void> deleteReaction(String noteId) async {
    await dio.post(
      '/api/notes/reactions/delete',
      data: createBody({'noteId': noteId}),
    );
  }

  /// POST /api/i/registry/get
  ///
  /// Returns the value stored at [key] under [scope] in the user registry.
  /// Returns `null` if the key does not exist (404).
  Future<dynamic> registryGet(String key, List<String> scope) async {
    try {
      final response = await dio.post(
        '/api/i/registry/get',
        data: createBody({'key': key, 'scope': scope}),
      );
      return response.data;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// POST /api/emojis
  Future<List<Map<String, dynamic>>> getEmojis() async {
    final response = await dio.post('/api/emojis', data: {});
    final emojis = response.data['emojis'] as List;
    return emojis.cast<Map<String, dynamic>>();
  }

  /// POST /api/users/search
  Future<List<MisskeyUser>> searchUsers(String query, {int? limit}) async {
    final response = await dio.post(
      '/api/users/search',
      data: createBody({'query': query, 'limit': ?limit}),
    );
    return (response.data as List)
        .map((e) => MisskeyUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/hashtags/search
  Future<List<String>> searchHashtags(String query, {int? limit}) async {
    final response = await dio.post(
      '/api/hashtags/search',
      data: createBody({'query': query, 'limit': ?limit}),
    );
    return (response.data as List).cast<String>();
  }

  /// POST /api/notes/search-by-tag
  Future<List<MisskeyNote>> searchByTag(
    String tag, {
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/notes/search-by-tag',
      data: createBody({
        'tag': tag,
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List)
        .map((e) => MisskeyNote.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/channels/timeline
  Future<List<MisskeyNote>> getChannelTimeline(
    String channelId, {
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/channels/timeline',
      data: createBody({
        'channelId': channelId,
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List)
        .map((e) => MisskeyNote.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/channels/followed
  Future<List<Map<String, dynamic>>> getFollowedChannels({
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/channels/followed',
      data: createBody({
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/flash/featured
  Future<List<Map<String, dynamic>>> getFeaturedFlashes() async {
    final response = await dio.post(
      '/api/flash/featured',
      data: createBody({}),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/clips/list
  Future<List<Map<String, dynamic>>> getClips() async {
    final response = await dio.post('/api/clips/list', data: createBody({}));
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/clips/notes
  Future<List<MisskeyNote>> getClipNotes(
    String clipId, {
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/clips/notes',
      data: createBody({
        'clipId': clipId,
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List)
        .map((e) => MisskeyNote.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/ap/show — resolve a remote URI to a local object.
  Future<Map<String, dynamic>> apShow(String uri) async {
    final response = await dio.post(
      '/api/ap/show',
      data: createBody({'uri': uri}),
    );
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/notes/hybrid-timeline (social = home + local)
  Future<List<MisskeyNote>> getHybridTimeline({
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/notes/hybrid-timeline',
      data: createBody({
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List)
        .map((e) => MisskeyNote.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/notes/local-timeline
  Future<List<MisskeyNote>> getLocalTimeline({
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/notes/local-timeline',
      data: createBody({
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List)
        .map((e) => MisskeyNote.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/notes/global-timeline
  Future<List<MisskeyNote>> getGlobalTimeline({
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/notes/global-timeline',
      data: createBody({
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List)
        .map((e) => MisskeyNote.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/users/lists/list
  Future<List<MisskeyList>> getLists() async {
    final response = await dio.post(
      '/api/users/lists/list',
      data: createBody(),
    );
    return (response.data as List)
        .map((e) => MisskeyList.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/users/lists/create
  Future<MisskeyList> createList(String name) async {
    final response = await dio.post(
      '/api/users/lists/create',
      data: createBody({'name': name}),
    );
    return MisskeyList.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/users/lists/update
  Future<MisskeyList> updateList(String listId, String name) async {
    final response = await dio.post(
      '/api/users/lists/update',
      data: createBody({'listId': listId, 'name': name}),
    );
    return MisskeyList.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/users/lists/delete
  Future<void> deleteList(String listId) async {
    await dio.post(
      '/api/users/lists/delete',
      data: createBody({'listId': listId}),
    );
  }

  /// POST /api/users/lists/show
  Future<Map<String, dynamic>> showList(String listId) async {
    final response = await dio.post(
      '/api/users/lists/show',
      data: createBody({'listId': listId}),
    );
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/users/lists/push
  Future<void> pushListUser(String listId, String userId) async {
    await dio.post(
      '/api/users/lists/push',
      data: createBody({'listId': listId, 'userId': userId}),
    );
  }

  /// POST /api/users/lists/pull
  Future<void> pullListUser(String listId, String userId) async {
    await dio.post(
      '/api/users/lists/pull',
      data: createBody({'listId': listId, 'userId': userId}),
    );
  }

  /// POST /api/notes/user-list-timeline
  Future<List<MisskeyNote>> getUserListTimeline(
    String listId, {
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/notes/user-list-timeline',
      data: createBody({
        'listId': listId,
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List)
        .map((e) => MisskeyNote.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> votePoll(String noteId, int choice) async {
    await dio.post(
      '/api/notes/polls/vote',
      data: createBody({'noteId': noteId, 'choice': choice}),
    );
  }

  /// POST /api/i/update
  Future<MisskeyUser> updateI({
    String? name,
    String? description,
    String? avatarId,
    String? bannerId,
    List<Map<String, String>>? fields,
  }) async {
    final params = <String, dynamic>{
      'avatarId': ?avatarId,
      'bannerId': ?bannerId,
      'fields': ?fields,
    };
    // Misskey rejects "" but accepts explicit null to clear a field.
    // null parameter = "not changing" (omit key), empty string = "clear" (send null value).
    if (name != null) {
      params['name'] = name.isEmpty ? null : name;
    }
    if (description != null) {
      params['description'] = description.isEmpty ? null : description;
    }
    final response = await dio.post('/api/i/update', data: createBody(params));
    return MisskeyUser.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/meta (no authentication required)
  Future<Map<String, dynamic>> getMeta() async {
    final response = await dio.post('/api/meta', data: {});
    return response.data as Map<String, dynamic>;
  }

  /// GET /url
  Future<Map<String, dynamic>> getUrlPreview(String url) async {
    final response = await dio.get('/url', queryParameters: {'url': url});
    return response.data as Map<String, dynamic>;
  }
}

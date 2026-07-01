import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:http_parser/http_parser.dart';

import '../rate_limit_interceptor.dart';

/// MiAuth の `/check` がセッションを承認済みとして返さなかった (`ok:false` /
/// token 欠落) ことを示す。MiAuth はユーザー承認とサーバー反映の間に僅かな
/// レースがあり、ループバックログイン (#276) で承認直後に `/check` を叩くと
/// この未承認応答が返ることがある。呼び出し側 (completeLogin) はこの例外を
/// 受けて短時間ポーリングし、恒久的失敗と区別する。
class MisskeyMiAuthPending implements Exception {
  const MisskeyMiAuthPending();
  @override
  String toString() => 'MisskeyMiAuthPending: MiAuth session not yet approved';
}

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
  ///
  /// MiAuth は未承認のセッションに対し HTTP 200 + `{ok: false}` (token/user
  /// 無し) を返す。承認済みなら `{ok: true, token, user}`。承認直後のレース
  /// (#276) で未承認応答が返った場合は [MisskeyMiAuthPending] を投げ、
  /// 呼び出し側のポーリングに委ねる (欠損フィールドの parse 失敗として
  /// 潰さない)。
  Future<MisskeyCheckSessionResponse> checkSession(String session) async {
    final response = await dio.post(
      '/api/miauth/$session/check',
      data: createBody(),
    );
    final data = response.data as Map<String, dynamic>;
    if (data['ok'] != true || data['token'] == null) {
      throw const MisskeyMiAuthPending();
    }
    return MisskeyCheckSessionResponse.fromJson(data);
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

  /// POST /api/users/achievements
  Future<List<Map<String, dynamic>>> getUserAchievements(String userId) async {
    final response = await dio.post(
      '/api/users/achievements',
      data: createBody({'userId': userId}),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
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
    String? folderId,
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
      'folderId': ?folderId,
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

  /// POST /api/drive/files
  Future<List<MisskeyDriveFile>> getDriveFiles({
    String? folderId,
    String? sinceId,
    String? untilId,
    int? limit,
    String? type,
  }) async {
    final response = await dio.post(
      '/api/drive/files',
      data: createBody({
        'folderId': ?folderId,
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
        'type': ?type,
      }),
    );
    return (response.data as List)
        .map((e) => MisskeyDriveFile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/drive/folders
  Future<List<Map<String, dynamic>>> getDriveFolders({
    String? folderId,
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/drive/folders',
      data: createBody({
        'folderId': ?folderId,
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/drive/files/update
  Future<MisskeyDriveFile> updateDriveFile(
    String fileId, {
    String? comment,
    String? name,
    String? folderId,
  }) async {
    final response = await dio.post(
      '/api/drive/files/update',
      data: createBody({
        'fileId': fileId,
        'comment': ?comment,
        'name': ?name,
        'folderId': ?folderId,
      }),
    );
    return MisskeyDriveFile.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/drive/files/delete
  Future<void> deleteDriveFile(String fileId) async {
    await dio.post(
      '/api/drive/files/delete',
      data: createBody({'fileId': fileId}),
    );
  }

  /// POST /api/drive/folders/create
  Future<Map<String, dynamic>> createDriveFolder(
    String name, {
    String? parentId,
  }) async {
    final response = await dio.post(
      '/api/drive/folders/create',
      data: createBody({'name': name, 'parentId': ?parentId}),
    );
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/drive/folders/delete
  Future<void> deleteDriveFolder(String folderId) async {
    await dio.post(
      '/api/drive/folders/delete',
      data: createBody({'folderId': folderId}),
    );
  }

  /// POST /api/drive/folders/update
  Future<Map<String, dynamic>> updateDriveFolder(
    String folderId, {
    String? name,
    String? parentId,
  }) async {
    final response = await dio.post(
      '/api/drive/folders/update',
      data: createBody({
        'folderId': folderId,
        'name': ?name,
        'parentId': ?parentId,
      }),
    );
    return response.data as Map<String, dynamic>;
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
    Map<String, dynamic>? poll,
    Map<String, String>? extraHeaders,
  }) async {
    final body = createBody({
      'text': text,
      'visibility': visibility,
      'replyId': ?replyId,
      'renoteId': ?renoteId,
      'fileIds': ?fileIds,
      'cw': ?cw,
      'localOnly': ?localOnly,
      'channelId': ?channelId,
      'poll': ?poll,
    });
    final response = await dio.post(
      '/api/notes/create',
      data: body,
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
    return (response.data as List)
        .where((e) {
          final json = e as Map<String, dynamic>;
          return json['scheduledAt'] != null;
        })
        .map((e) {
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
                (json['fileIds'] as List?)
                    ?.map((id) => id as String)
                    .toList() ??
                [],
          );
        })
        .toList();
  }

  /// POST /api/notes/drafts/update — update a scheduled note's text.
  Future<void> updateScheduledNote({
    required String draftId,
    required String text,
    required DateTime scheduledAt,
  }) async {
    await dio.post(
      '/api/notes/drafts/update',
      data: createBody({
        'draftId': draftId,
        'text': text,
        'scheduledAt': scheduledAt.toUtc().millisecondsSinceEpoch,
        'isActuallyScheduled': true,
      }),
    );
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
  ///
  /// [type] を渡すと特定の絵文字でリアクションしたユーザーのみに絞り込む
  /// （リアクションキーをそのまま渡す。例: `:name@.:` / unicode）。
  Future<List<Map<String, dynamic>>> getNoteReactions(
    String noteId, {
    String? untilId,
    int? limit,
    String? type,
  }) async {
    final response = await dio.post(
      '/api/notes/reactions',
      data: createBody({
        'noteId': noteId,
        'untilId': ?untilId,
        'limit': ?limit,
        'type': ?type,
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
  Future<MisskeyNote> renote(String noteId, {String? visibility}) async {
    final response = await dio.post(
      '/api/notes/create',
      data: createBody({'renoteId': noteId, 'visibility': ?visibility}),
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

  /// POST /api/gallery/featured
  Future<List<Map<String, dynamic>>> getGalleryFeatured({
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/gallery/featured',
      data: createBody({
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/users/gallery/posts
  Future<List<Map<String, dynamic>>> getUserGalleryPosts(
    String userId, {
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/users/gallery/posts',
      data: createBody({
        'userId': userId,
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/notes/translate
  Future<Map<String, dynamic>> translateNote(
    String noteId, {
    String targetLang = 'ja',
  }) async {
    final response = await dio.post(
      '/api/notes/translate',
      data: createBody({'noteId': noteId, 'targetLang': targetLang}),
    );
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/users/pages
  Future<List<Map<String, dynamic>>> getUserPages(
    String userId, {
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/users/pages',
      data: createBody({
        'userId': userId,
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/pages/show (by id)
  Future<Map<String, dynamic>> getPageById(String pageId) async {
    final response = await dio.post(
      '/api/pages/show',
      data: createBody({'pageId': pageId}),
    );
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/pages/show (by username + name)
  Future<Map<String, dynamic>> getPageByName({
    required String username,
    required String name,
  }) async {
    final response = await dio.post(
      '/api/pages/show',
      data: createBody({'username': username, 'name': name}),
    );
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/pages/featured
  Future<List<Map<String, dynamic>>> getFeaturedPages({int? limit}) async {
    final response = await dio.post(
      '/api/pages/featured',
      data: createBody({'limit': ?limit}),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/i/page-likes
  ///
  /// Returns an array of `{ id, page }` entries. Caller is responsible for
  /// extracting `page` from each entry.
  Future<List<Map<String, dynamic>>> getMyPageLikes({
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/i/page-likes',
      data: createBody({
        'sinceId': ?sinceId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/pages/like
  Future<void> likePage(String pageId) async {
    await dio.post('/api/pages/like', data: createBody({'pageId': pageId}));
  }

  /// POST /api/pages/unlike
  Future<void> unlikePage(String pageId) async {
    await dio.post('/api/pages/unlike', data: createBody({'pageId': pageId}));
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

  /// POST /api/antennas/list
  Future<List<Map<String, dynamic>>> getAntennas() async {
    final response = await dio.post('/api/antennas/list', data: createBody({}));
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/antennas/notes
  Future<List<MisskeyNote>> getAntennaNotes(
    String antennaId, {
    String? sinceId,
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/antennas/notes',
      data: createBody({
        'antennaId': antennaId,
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

  /// POST /api/ping
  Future<Map<String, dynamic>> ping() async {
    final response = await dio.post('/api/ping', data: {});
    return response.data as Map<String, dynamic>;
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

  /// POST /api/chat/history
  ///
  /// Misskey 本家 endpoints/chat/history.ts の paramDef は `{limit, room}` のみで、
  /// `untilId` はサーバー側で paramDef に無く Ajv が黙殺するため受け付けない
  /// (#445)。ページングは非対応。`limit=100` 程度の一回取り運用が想定。
  ///
  /// [room] を true にするとルームスレッドの履歴 (ChatMessageDetailed の
  /// `toRoomId` / `toRoom` 形) を返す (#438)。
  Future<List<Map<String, dynamic>>> getChatHistory({
    int? limit,
    bool room = false,
  }) async {
    final response = await dio.post(
      '/api/chat/history',
      data: createBody({'limit': ?limit, 'room': room}),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/chat/messages/user-timeline
  Future<List<Map<String, dynamic>>> getChatUserMessages({
    required String userId,
    String? untilId,
    String? sinceId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/chat/messages/user-timeline',
      data: createBody({
        'userId': userId,
        'untilId': ?untilId,
        'sinceId': ?sinceId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/chat/messages/create-to-user
  Future<Map<String, dynamic>> createChatMessageToUser({
    required String toUserId,
    String? text,
    String? fileId,
  }) async {
    final response = await dio.post(
      '/api/chat/messages/create-to-user',
      data: createBody({
        'toUserId': toUserId,
        'text': ?text,
        'fileId': ?fileId,
      }),
    );
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/chat/messages/delete
  Future<void> deleteChatMessage(String messageId) async {
    await dio.post(
      '/api/chat/messages/delete',
      data: createBody({'messageId': messageId}),
    );
  }

  /// POST /api/chat/read-all
  Future<void> markAllChatRead() async {
    await dio.post('/api/chat/read-all', data: createBody());
  }

  /// POST /api/chat/messages/react (#612)
  Future<void> reactToChatMessage({
    required String messageId,
    required String reaction,
  }) async {
    await dio.post(
      '/api/chat/messages/react',
      data: createBody({'messageId': messageId, 'reaction': reaction}),
    );
  }

  /// POST /api/chat/messages/unreact (#612)
  Future<void> unreactToChatMessage({
    required String messageId,
    required String reaction,
  }) async {
    await dio.post(
      '/api/chat/messages/unreact',
      data: createBody({'messageId': messageId, 'reaction': reaction}),
    );
  }

  // === chat rooms (#438) =====================================================

  /// POST /api/chat/messages/room-timeline
  Future<List<Map<String, dynamic>>> getChatRoomMessages({
    required String roomId,
    String? untilId,
    String? sinceId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/chat/messages/room-timeline',
      data: createBody({
        'roomId': roomId,
        'untilId': ?untilId,
        'sinceId': ?sinceId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/chat/messages/create-to-room
  Future<Map<String, dynamic>> createChatMessageToRoom({
    required String toRoomId,
    String? text,
    String? fileId,
  }) async {
    final response = await dio.post(
      '/api/chat/messages/create-to-room',
      data: createBody({
        'toRoomId': toRoomId,
        'text': ?text,
        'fileId': ?fileId,
      }),
    );
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/chat/rooms/create
  Future<Map<String, dynamic>> createChatRoom({
    required String name,
    String? description,
  }) async {
    final response = await dio.post(
      '/api/chat/rooms/create',
      data: createBody({'name': name, 'description': ?description}),
    );
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/chat/rooms/show
  Future<Map<String, dynamic>> getChatRoom(String roomId) async {
    final response = await dio.post(
      '/api/chat/rooms/show',
      data: createBody({'roomId': roomId}),
    );
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/chat/rooms/update
  Future<Map<String, dynamic>> updateChatRoom({
    required String roomId,
    String? name,
    String? description,
  }) async {
    final response = await dio.post(
      '/api/chat/rooms/update',
      data: createBody({
        'roomId': roomId,
        'name': ?name,
        'description': ?description,
      }),
    );
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/chat/rooms/delete
  Future<void> deleteChatRoom(String roomId) async {
    await dio.post(
      '/api/chat/rooms/delete',
      data: createBody({'roomId': roomId}),
    );
  }

  /// POST /api/chat/rooms/join
  Future<Map<String, dynamic>> joinChatRoom(String roomId) async {
    final response = await dio.post(
      '/api/chat/rooms/join',
      data: createBody({'roomId': roomId}),
    );
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/chat/rooms/leave
  Future<void> leaveChatRoom(String roomId) async {
    await dio.post(
      '/api/chat/rooms/leave',
      data: createBody({'roomId': roomId}),
    );
  }

  /// POST /api/chat/rooms/joining
  Future<List<Map<String, dynamic>>> getJoiningChatRooms({
    String? untilId,
    String? sinceId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/chat/rooms/joining',
      data: createBody({
        'untilId': ?untilId,
        'sinceId': ?sinceId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/chat/rooms/owned
  Future<List<Map<String, dynamic>>> getOwnedChatRooms({
    String? untilId,
    String? sinceId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/chat/rooms/owned',
      data: createBody({
        'untilId': ?untilId,
        'sinceId': ?sinceId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/chat/rooms/members
  Future<List<Map<String, dynamic>>> getChatRoomMembers({
    required String roomId,
    String? untilId,
    String? sinceId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/chat/rooms/members',
      data: createBody({
        'roomId': roomId,
        'untilId': ?untilId,
        'sinceId': ?sinceId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/chat/rooms/mute
  ///
  /// 自分の view から指定ルームをミュート / アンミュート。Misskey 本家 mute.ts の
  /// paramDef は `{ roomId, mute: boolean }`。
  Future<void> setChatRoomMute({
    required String roomId,
    required bool mute,
  }) async {
    await dio.post(
      '/api/chat/rooms/mute',
      data: createBody({'roomId': roomId, 'mute': mute}),
    );
  }

  /// POST /api/chat/rooms/invitations/create
  Future<Map<String, dynamic>> createChatRoomInvitation({
    required String roomId,
    required String userId,
  }) async {
    final response = await dio.post(
      '/api/chat/rooms/invitations/create',
      data: createBody({'roomId': roomId, 'userId': userId}),
    );
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/chat/rooms/invitations/ignore
  Future<void> ignoreChatRoomInvitation(String roomId) async {
    await dio.post(
      '/api/chat/rooms/invitations/ignore',
      data: createBody({'roomId': roomId}),
    );
  }

  /// POST /api/chat/rooms/invitations/inbox
  Future<List<Map<String, dynamic>>> getChatRoomInvitationInbox({
    String? untilId,
    String? sinceId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/chat/rooms/invitations/inbox',
      data: createBody({
        'untilId': ?untilId,
        'sinceId': ?sinceId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/chat/rooms/invitations/outbox
  Future<List<Map<String, dynamic>>> getChatRoomInvitationOutbox({
    String? untilId,
    String? sinceId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/chat/rooms/invitations/outbox',
      data: createBody({
        'untilId': ?untilId,
        'sinceId': ?sinceId,
        'limit': ?limit,
      }),
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// Web Push サブスクリプション登録。POST /api/sw/register
  ///
  /// Mastodon 側の [MastodonClient.subscribePush] と対で、3 層（interface /
  /// adapter / client）で同一名に統一している。
  Future<Map<String, dynamic>> subscribePush({
    required String endpoint,
    required String publickey,
    required String auth,
  }) async {
    final response = await dio.post(
      '/api/sw/register',
      data: createBody({
        'endpoint': endpoint,
        'publickey': publickey,
        'auth': auth,
      }),
    );
    return response.data as Map<String, dynamic>;
  }

  /// Web Push サブスクリプション解除。POST /api/sw/unregister
  Future<void> unsubscribePush({required String endpoint}) async {
    await dio.post(
      '/api/sw/unregister',
      data: createBody({'endpoint': endpoint}),
    );
  }
}

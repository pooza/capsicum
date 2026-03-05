import 'package:dio/dio.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:http_parser/http_parser.dart';

class MisskeyClient {
  final Dio dio;
  final String host;
  String? _token;

  MisskeyClient(this.host) : dio = Dio(BaseOptions(baseUrl: 'https://$host'));

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

  /// POST /api/users/notes
  Future<List<MisskeyNote>> getUserNotes(
    String userId, {
    String? untilId,
    int? limit,
  }) async {
    final response = await dio.post(
      '/api/users/notes',
      data: createBody({
        'userId': userId,
        'untilId': ?untilId,
        'limit': ?limit,
      }),
    );
    return (response.data as List)
        .map((e) => MisskeyNote.fromJson(e as Map<String, dynamic>))
        .toList();
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
  }) async {
    final fileName = filePath.split('/').last;
    final mediaType = mimeType != null
        ? MediaType.parse(mimeType)
        : null;
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(
        filePath,
        filename: fileName,
        contentType: mediaType,
      ),
      'comment': ?comment,
      if (_token != null) 'i': _token,
    });
    final response = await dio.post('/api/drive/files/create', data: formData);
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/notes/create
  Future<MisskeyNote> createNote({
    required String text,
    required String visibility,
    String? replyId,
    List<String>? fileIds,
  }) async {
    final response = await dio.post(
      '/api/notes/create',
      data: createBody({
        'text': text,
        'visibility': visibility,
        'replyId': ?replyId,
        'fileIds': ?fileIds,
      }),
    );
    return MisskeyNote.fromJson(
      (response.data as Map<String, dynamic>)['createdNote']
          as Map<String, dynamic>,
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
        .map((e) => MisskeyNote.fromJson(
            (e as Map<String, dynamic>)['note'] as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/announcements
  Future<List<MisskeyAnnouncement>> getAnnouncements({int? limit}) async {
    final response = await dio.post(
      '/api/announcements',
      data: createBody({'limit': ?limit}),
    );
    return (response.data as List)
        .map((e) =>
            MisskeyAnnouncement.fromJson(e as Map<String, dynamic>))
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
}

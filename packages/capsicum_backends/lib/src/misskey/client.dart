import 'package:dio/dio.dart';
import 'package:fediverse_objects/fediverse_objects.dart';

class MisskeyClient {
  final Dio dio;
  final String host;
  String? _token;

  MisskeyClient(this.host) : dio = Dio(BaseOptions(baseUrl: 'https://$host'));

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

  /// POST /api/notes/create
  Future<MisskeyNote> createNote({
    required String text,
    required String visibility,
    String? replyId,
  }) async {
    final response = await dio.post(
      '/api/notes/create',
      data: createBody({
        'text': text,
        'visibility': visibility,
        'replyId': ?replyId,
      }),
    );
    return MisskeyNote.fromJson(
      (response.data as Map<String, dynamic>)['createdNote']
          as Map<String, dynamic>,
    );
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

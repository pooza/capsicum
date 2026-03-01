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

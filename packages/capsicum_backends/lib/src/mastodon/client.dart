import 'package:dio/dio.dart';
import 'package:fediverse_objects/fediverse_objects.dart';

class MastodonClient {
  final Dio dio;
  final String host;

  MastodonClient(this.host) : dio = Dio(BaseOptions(baseUrl: 'https://$host'));

  void setAccessToken(String token) {
    dio.options.headers['Authorization'] = 'Bearer $token';
  }

  /// POST /api/v1/apps
  Future<MastodonApplication> createApplication({
    required String clientName,
    required String redirectUris,
    required String scopes,
    String? website,
  }) async {
    final response = await dio.post('/api/v1/apps', data: {
      'client_name': clientName,
      'redirect_uris': redirectUris,
      'scopes': scopes,
      'website': ?website,
    });
    return MastodonApplication.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// POST /oauth/token
  Future<MastodonToken> getToken({
    required String grantType,
    required String clientId,
    required String clientSecret,
    required String redirectUri,
    String? code,
    String? scope,
  }) async {
    final response = await dio.post('/oauth/token', data: {
      'grant_type': grantType,
      'client_id': clientId,
      'client_secret': clientSecret,
      'redirect_uri': redirectUri,
      'code': ?code,
      'scope': ?scope,
    });
    return MastodonToken.fromJson(response.data as Map<String, dynamic>);
  }

  /// GET /api/v1/accounts/verify_credentials
  Future<MastodonAccount> verifyCredentials() async {
    final response = await dio.get('/api/v1/accounts/verify_credentials');
    return MastodonAccount.fromJson(response.data as Map<String, dynamic>);
  }

  /// GET /api/v1/timelines/home
  Future<List<MastodonStatus>> getHomeTimeline({
    String? maxId,
    String? sinceId,
    String? minId,
    int? limit,
  }) async {
    final response = await dio.get(
      '/api/v1/timelines/home',
      queryParameters: {
        'max_id': ?maxId,
        'since_id': ?sinceId,
        'min_id': ?minId,
        'limit': ?limit,
      },
    );
    return (response.data as List)
        .map((e) => MastodonStatus.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/v1/statuses
  Future<MastodonStatus> postStatus({
    required String status,
    required String visibility,
    String? inReplyToId,
    String? spoilerText,
  }) async {
    final response = await dio.post('/api/v1/statuses', data: {
      'status': status,
      'visibility': visibility,
      'in_reply_to_id': ?inReplyToId,
      'spoiler_text': ?spoilerText,
    });
    return MastodonStatus.fromJson(response.data as Map<String, dynamic>);
  }

  /// GET /api/v1/timelines/public
  Future<List<MastodonStatus>> getPublicTimeline({
    bool? local,
    String? maxId,
    String? sinceId,
    int? limit,
  }) async {
    final response = await dio.get(
      '/api/v1/timelines/public',
      queryParameters: {
        'local': ?local,
        'max_id': ?maxId,
        'since_id': ?sinceId,
        'limit': ?limit,
      },
    );
    return (response.data as List)
        .map((e) => MastodonStatus.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

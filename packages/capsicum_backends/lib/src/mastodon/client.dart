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

  /// GET /api/v1/statuses/:id
  Future<MastodonStatus> getStatus(String id) async {
    final response = await dio.get('/api/v1/statuses/$id');
    return MastodonStatus.fromJson(response.data as Map<String, dynamic>);
  }

  /// GET /api/v1/statuses/:id/context
  /// Returns { ancestors: [Status], descendants: [Status] }.
  Future<({List<MastodonStatus> ancestors, List<MastodonStatus> descendants})>
      getStatusContext(String id) async {
    final response = await dio.get('/api/v1/statuses/$id/context');
    final data = response.data as Map<String, dynamic>;
    return (
      ancestors: (data['ancestors'] as List)
          .map((e) => MastodonStatus.fromJson(e as Map<String, dynamic>))
          .toList(),
      descendants: (data['descendants'] as List)
          .map((e) => MastodonStatus.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// POST /api/v1/statuses/:id/favourite
  Future<MastodonStatus> favouriteStatus(String id) async {
    final response = await dio.post('/api/v1/statuses/$id/favourite');
    return MastodonStatus.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/v1/statuses/:id/unfavourite
  Future<MastodonStatus> unfavouriteStatus(String id) async {
    final response = await dio.post('/api/v1/statuses/$id/unfavourite');
    return MastodonStatus.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/v1/statuses/:id/reblog
  Future<MastodonStatus> reblogStatus(String id) async {
    final response = await dio.post('/api/v1/statuses/$id/reblog');
    return MastodonStatus.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/v1/statuses/:id/unreblog
  Future<MastodonStatus> unreblogStatus(String id) async {
    final response = await dio.post('/api/v1/statuses/$id/unreblog');
    return MastodonStatus.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/v1/statuses/:id/bookmark
  Future<MastodonStatus> bookmarkStatus(String id) async {
    final response = await dio.post('/api/v1/statuses/$id/bookmark');
    return MastodonStatus.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/v1/statuses/:id/unbookmark
  Future<MastodonStatus> unbookmarkStatus(String id) async {
    final response = await dio.post('/api/v1/statuses/$id/unbookmark');
    return MastodonStatus.fromJson(response.data as Map<String, dynamic>);
  }

  /// GET /api/v1/notifications
  Future<List<MastodonNotification>> getNotifications({
    String? maxId,
    String? sinceId,
    int? limit,
  }) async {
    final response = await dio.get(
      '/api/v1/notifications',
      queryParameters: {
        'max_id': ?maxId,
        'since_id': ?sinceId,
        'limit': ?limit,
      },
    );
    return (response.data as List)
        .map((e) => MastodonNotification.fromJson(e as Map<String, dynamic>))
        .toList();
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

import 'package:dio/dio.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:http_parser/http_parser.dart';

class MastodonClient {
  final Dio dio;
  final String host;
  String? _accessToken;

  MastodonClient(this.host) : dio = Dio(BaseOptions(baseUrl: 'https://$host'));

  String? get accessToken => _accessToken;

  void setAccessToken(String token) {
    _accessToken = token;
    dio.options.headers['Authorization'] = 'Bearer $token';
  }

  /// POST /api/v1/apps
  Future<MastodonApplication> createApplication({
    required String clientName,
    required String redirectUris,
    required String scopes,
    String? website,
  }) async {
    final response = await dio.post(
      '/api/v1/apps',
      data: {
        'client_name': clientName,
        'redirect_uris': redirectUris,
        'scopes': scopes,
        'website': ?website,
      },
    );
    return MastodonApplication.fromJson(response.data as Map<String, dynamic>);
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
    final response = await dio.post(
      '/oauth/token',
      data: {
        'grant_type': grantType,
        'client_id': clientId,
        'client_secret': clientSecret,
        'redirect_uri': redirectUri,
        'code': ?code,
        'scope': ?scope,
      },
    );
    return MastodonToken.fromJson(response.data as Map<String, dynamic>);
  }

  /// GET /api/v1/accounts/verify_credentials
  Future<MastodonAccount> verifyCredentials() async {
    final response = await dio.get('/api/v1/accounts/verify_credentials');
    return MastodonAccount.fromJson(response.data as Map<String, dynamic>);
  }

  /// GET /api/v1/accounts/:id
  Future<MastodonAccount> getAccount(String id) async {
    final response = await dio.get('/api/v1/accounts/$id');
    return MastodonAccount.fromJson(response.data as Map<String, dynamic>);
  }

  /// GET /api/v1/accounts/:id/statuses
  Future<List<MastodonStatus>> getAccountStatuses(
    String id, {
    String? maxId,
    int? limit,
    bool? pinned,
  }) async {
    final response = await dio.get(
      '/api/v1/accounts/$id/statuses',
      queryParameters: {'max_id': ?maxId, 'limit': ?limit, 'pinned': ?pinned},
    );
    return (response.data as List)
        .map((e) => MastodonStatus.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /api/v1/accounts/:id/followers
  Future<({List<MastodonAccount> accounts, String? nextMaxId})>
  getAccountFollowers(String id, {String? maxId, int? limit}) async {
    final response = await dio.get(
      '/api/v1/accounts/$id/followers',
      queryParameters: {'max_id': ?maxId, 'limit': ?limit},
    );
    final accounts = (response.data as List)
        .map((e) => MastodonAccount.fromJson(e as Map<String, dynamic>))
        .toList();
    return (accounts: accounts, nextMaxId: _parseLinkNextMaxId(response));
  }

  /// GET /api/v1/accounts/:id/following
  Future<({List<MastodonAccount> accounts, String? nextMaxId})>
  getAccountFollowing(String id, {String? maxId, int? limit}) async {
    final response = await dio.get(
      '/api/v1/accounts/$id/following',
      queryParameters: {'max_id': ?maxId, 'limit': ?limit},
    );
    final accounts = (response.data as List)
        .map((e) => MastodonAccount.fromJson(e as Map<String, dynamic>))
        .toList();
    return (accounts: accounts, nextMaxId: _parseLinkNextMaxId(response));
  }

  /// Parse the Link header to extract max_id from rel="next".
  static String? _parseLinkNextMaxId(dynamic response) {
    final link = response.headers.value('link');
    if (link == null) return null;
    final nextMatch = RegExp(
      r'<[^>]*[?&]max_id=([^&>]+)[^>]*>;\s*rel="next"',
    ).firstMatch(link);
    return nextMatch?.group(1);
  }

  /// GET /api/v1/accounts/relationships
  Future<List<Map<String, dynamic>>> getRelationships(List<String> ids) async {
    final response = await dio.get(
      '/api/v1/accounts/relationships',
      queryParameters: {'id[]': ids},
    );
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// POST /api/v1/accounts/:id/follow
  Future<void> followAccount(String id) async {
    await dio.post('/api/v1/accounts/$id/follow');
  }

  /// POST /api/v1/accounts/:id/unfollow
  Future<void> unfollowAccount(String id) async {
    await dio.post('/api/v1/accounts/$id/unfollow');
  }

  /// POST /api/v1/accounts/:id/mute
  Future<void> muteAccount(String id, {int? duration}) async {
    await dio.post(
      '/api/v1/accounts/$id/mute',
      data: {'duration': duration ?? 0},
    );
  }

  /// POST /api/v1/accounts/:id/unmute
  Future<void> unmuteAccount(String id) async {
    await dio.post('/api/v1/accounts/$id/unmute');
  }

  /// POST /api/v1/accounts/:id/block
  Future<void> blockAccount(String id) async {
    await dio.post('/api/v1/accounts/$id/block');
  }

  /// POST /api/v1/accounts/:id/unblock
  Future<void> unblockAccount(String id) async {
    await dio.post('/api/v1/accounts/$id/unblock');
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
    List<String>? mediaIds,
    bool? sensitive,
    Map<String, String>? extraHeaders,
  }) async {
    final response = await dio.post(
      '/api/v1/statuses',
      data: {
        'status': status,
        'visibility': visibility,
        'in_reply_to_id': ?inReplyToId,
        'spoiler_text': ?spoilerText,
        'media_ids': ?mediaIds,
        'sensitive': ?sensitive,
      },
      options: extraHeaders != null ? Options(headers: extraHeaders) : null,
    );
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

  /// POST /api/v1/media
  ///
  /// v1 は同期処理で、トランスコード完了後に 200 + 完全な JSON を返す。
  /// モロヘイヤ経由の場合も安定して動作する。
  Future<MastodonMediaAttachment> uploadMedia(
    String filePath, {
    String? mimeType,
  }) async {
    final fileName = filePath.split('/').last;
    final mediaType = mimeType != null ? MediaType.parse(mimeType) : null;
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(
        filePath,
        filename: fileName,
        contentType: mediaType,
      ),
    });
    final response = await dio.post('/api/v1/media', data: formData);
    return MastodonMediaAttachment.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// PUT /api/v1/media/:id
  Future<MastodonMediaAttachment> updateMedia(
    String id, {
    String? description,
  }) async {
    final response = await dio.put(
      '/api/v1/media/$id',
      data: {'description': ?description},
    );
    return MastodonMediaAttachment.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// GET /api/v1/bookmarks
  Future<List<MastodonStatus>> getBookmarks({
    String? maxId,
    String? sinceId,
    int? limit,
  }) async {
    final response = await dio.get(
      '/api/v1/bookmarks',
      queryParameters: {
        'max_id': ?maxId,
        'since_id': ?sinceId,
        'limit': ?limit,
      },
    );
    return (response.data as List)
        .map((e) => MastodonStatus.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /api/v1/announcements
  Future<List<MastodonAnnouncement>> getAnnouncements() async {
    final response = await dio.get('/api/v1/announcements');
    return (response.data as List)
        .map((e) => MastodonAnnouncement.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/v1/announcements/:id/dismiss
  Future<void> dismissAnnouncement(String id) async {
    await dio.post('/api/v1/announcements/$id/dismiss');
  }

  /// DELETE /api/v1/statuses/:id
  Future<void> deleteStatus(String id) async {
    await dio.delete('/api/v1/statuses/$id');
  }

  /// GET /api/v2/search
  Future<Map<String, dynamic>> search(
    String query, {
    String? type,
    bool? resolve,
    int? limit,
  }) async {
    final response = await dio.get(
      '/api/v2/search',
      queryParameters: {
        'q': query,
        'type': ?type,
        'resolve': ?resolve,
        'limit': ?limit,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  /// GET /api/v1/timelines/tag/:hashtag
  Future<List<MastodonStatus>> getTagTimeline(
    String hashtag, {
    String? maxId,
    String? sinceId,
    int? limit,
  }) async {
    final response = await dio.get(
      '/api/v1/timelines/tag/${Uri.encodeComponent(hashtag)}',
      queryParameters: {
        'max_id': ?maxId,
        'since_id': ?sinceId,
        'limit': ?limit,
      },
    );
    return (response.data as List)
        .map((e) => MastodonStatus.fromJson(e as Map<String, dynamic>))
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

  /// GET /api/v1/lists
  Future<List<MastodonList>> getLists() async {
    final response = await dio.get('/api/v1/lists');
    return (response.data as List)
        .map((e) => MastodonList.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/v1/lists
  Future<MastodonList> createList(String title) async {
    final response = await dio.post('/api/v1/lists', data: {'title': title});
    return MastodonList.fromJson(response.data as Map<String, dynamic>);
  }

  /// PUT /api/v1/lists/:id
  Future<MastodonList> updateList(String id, String title) async {
    final response = await dio.put('/api/v1/lists/$id', data: {'title': title});
    return MastodonList.fromJson(response.data as Map<String, dynamic>);
  }

  /// DELETE /api/v1/lists/:id
  Future<void> deleteList(String id) async {
    await dio.delete('/api/v1/lists/$id');
  }

  /// GET /api/v1/timelines/list/:id
  Future<List<MastodonStatus>> getListTimeline(
    String listId, {
    String? maxId,
    String? sinceId,
    int? limit,
  }) async {
    final response = await dio.get(
      '/api/v1/timelines/list/$listId',
      queryParameters: {
        'max_id': ?maxId,
        'since_id': ?sinceId,
        'limit': ?limit,
      },
    );
    return (response.data as List)
        .map((e) => MastodonStatus.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> votePoll(String pollId, List<int> choices) async {
    await dio.post('/api/v1/polls/$pollId/votes', data: {'choices': choices});
  }
}

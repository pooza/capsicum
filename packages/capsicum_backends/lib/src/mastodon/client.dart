import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:http_parser/http_parser.dart';

import '../rate_limit_interceptor.dart';

class MastodonClient {
  final Dio dio;
  final String host;
  String? _accessToken;

  MastodonClient(this.host) : dio = Dio(BaseOptions(baseUrl: 'https://$host')) {
    dio.interceptors.add(RateLimitInterceptor(dio));
  }

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

  /// GET /api/v1/accounts/lookup
  Future<MastodonAccount?> lookupAccount(String acct) async {
    try {
      final response = await dio.get(
        '/api/v1/accounts/lookup',
        queryParameters: {'acct': acct},
      );
      return MastodonAccount.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// GET /api/v1/accounts/:id/statuses
  Future<List<MastodonStatus>> getAccountStatuses(
    String id, {
    String? maxId,
    int? limit,
    bool? pinned,
    bool? onlyMedia,
  }) async {
    final response = await dio.get(
      '/api/v1/accounts/$id/statuses',
      queryParameters: {
        'max_id': ?maxId,
        'limit': ?limit,
        'pinned': ?pinned,
        'only_media': ?onlyMedia,
      },
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

  /// GET /api/v1/statuses/:id/favourited_by
  Future<({List<MastodonAccount> accounts, String? nextMaxId})> getFavouritedBy(
    String id, {
    String? maxId,
    int? limit,
  }) async {
    final response = await dio.get(
      '/api/v1/statuses/$id/favourited_by',
      queryParameters: {'max_id': ?maxId, 'limit': ?limit},
    );
    final accounts = (response.data as List)
        .map((e) => MastodonAccount.fromJson(e as Map<String, dynamic>))
        .toList();
    return (accounts: accounts, nextMaxId: _parseLinkNextMaxId(response));
  }

  /// GET /api/v1/statuses/:id/reblogged_by
  Future<({List<MastodonAccount> accounts, String? nextMaxId})> getRebloggedBy(
    String id, {
    String? maxId,
    int? limit,
  }) async {
    final response = await dio.get(
      '/api/v1/statuses/$id/reblogged_by',
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
    String? quoteId,
    String? spoilerText,
    List<String>? mediaIds,
    bool? sensitive,
    String? language,
    List<String>? pollOptions,
    int? pollExpiresIn,
    bool? pollMultiple,
    bool? pollHideTotals,
    String? quoteApprovalPolicy,
    Map<String, String>? extraHeaders,
  }) async {
    final data = <String, dynamic>{
      'status': status,
      'visibility': visibility,
      'in_reply_to_id': ?inReplyToId,
      'quoted_status_id': ?quoteId,
      'spoiler_text': ?spoilerText,
      'media_ids': ?mediaIds,
      'sensitive': ?sensitive,
      'language': ?language,
      'quote_approval_policy': ?quoteApprovalPolicy,
    };
    if (pollOptions != null && pollOptions.isNotEmpty) {
      data['poll'] = {
        'options': pollOptions,
        'expires_in': pollExpiresIn ?? 86400,
        'multiple': pollMultiple ?? false,
        'hide_totals': pollHideTotals ?? false,
      };
    }
    final response = await dio.post(
      '/api/v1/statuses',
      data: data,
      options: extraHeaders != null ? Options(headers: extraHeaders) : null,
    );
    return MastodonStatus.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/v1/statuses with scheduled_at.
  /// Returns the raw ScheduledStatus JSON (different from regular Status).
  Future<void> scheduleStatus({
    required String status,
    required String visibility,
    required String scheduledAt,
    String? inReplyToId,
    String? quoteId,
    String? spoilerText,
    List<String>? mediaIds,
    bool? sensitive,
    String? language,
    String? quoteApprovalPolicy,
    Map<String, String>? extraHeaders,
  }) async {
    await dio.post(
      '/api/v1/statuses',
      data: {
        'status': status,
        'visibility': visibility,
        'scheduled_at': scheduledAt,
        'in_reply_to_id': ?inReplyToId,
        'quoted_status_id': ?quoteId,
        'spoiler_text': ?spoilerText,
        'media_ids': ?mediaIds,
        'sensitive': ?sensitive,
        'language': ?language,
        'quote_approval_policy': ?quoteApprovalPolicy,
      },
      options: extraHeaders != null ? Options(headers: extraHeaders) : null,
    );
  }

  /// GET /api/v1/scheduled_statuses
  Future<List<ScheduledPost>> getScheduledStatuses() async {
    final response = await dio.get('/api/v1/scheduled_statuses');
    return (response.data as List).map((e) {
      final json = e as Map<String, dynamic>;
      final params = json['params'] as Map<String, dynamic>? ?? {};
      return ScheduledPost(
        id: json['id'] as String,
        scheduledAt: DateTime.parse(json['scheduled_at'] as String),
        content: params['text'] as String?,
        spoilerText: params['spoiler_text'] as String?,
        visibility: params['visibility'] as String?,
        mediaIds:
            (json['media_attachments'] as List?)
                ?.map((m) => (m as Map<String, dynamic>)['id'] as String)
                .toList() ??
            [],
      );
    }).toList();
  }

  /// DELETE /api/v1/scheduled_statuses/:id
  Future<void> deleteScheduledStatus(String id) async {
    await dio.delete('/api/v1/scheduled_statuses/$id');
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

  /// POST /api/v1/statuses/:id/pin
  Future<MastodonStatus> pinStatus(String id) async {
    final response = await dio.post('/api/v1/statuses/$id/pin');
    return MastodonStatus.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/v1/statuses/:id/unpin
  Future<MastodonStatus> unpinStatus(String id) async {
    final response = await dio.post('/api/v1/statuses/$id/unpin');
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

  /// GET /api/v1/conversations
  /// Returns the last_status from each conversation (DM thread).
  Future<List<MastodonStatus>> getConversations({
    String? maxId,
    String? sinceId,
    int? limit,
  }) async {
    final response = await dio.get(
      '/api/v1/conversations',
      queryParameters: {
        'max_id': ?maxId,
        'since_id': ?sinceId,
        'limit': ?limit,
      },
    );
    final conversations = response.data as List;
    return conversations
        .map((e) {
          final m = e as Map<String, dynamic>;
          final lastStatus = m['last_status'];
          if (lastStatus == null) return null;
          return MastodonStatus.fromJson(lastStatus as Map<String, dynamic>);
        })
        .whereType<MastodonStatus>()
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

    Future<FormData> buildFormData() async => FormData.fromMap({
      'file': await MultipartFile.fromFile(
        filePath,
        filename: fileName,
        contentType: mediaType,
      ),
    });

    final formData = await buildFormData();
    final response = await dio.post(
      '/api/v1/media',
      data: formData,
      options: Options(
        extra: {RateLimitInterceptor.formDataFactoryKey: buildFormData},
      ),
    );
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

  /// POST /api/v1/reports
  Future<void> createReport(
    String accountId, {
    List<String>? statusIds,
    String? comment,
  }) async {
    await dio.post(
      '/api/v1/reports',
      data: {
        'account_id': accountId,
        'status_ids': ?statusIds,
        'comment': ?comment,
      },
    );
  }

  /// GET /api/v1/accounts/search
  Future<List<MastodonAccount>> searchAccounts(
    String query, {
    int? limit,
    bool? resolve,
  }) async {
    final response = await dio.get(
      '/api/v1/accounts/search',
      queryParameters: {'q': query, 'limit': ?limit, 'resolve': ?resolve},
    );
    return (response.data as List)
        .map((e) => MastodonAccount.fromJson(e as Map<String, dynamic>))
        .toList();
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

  /// GET /api/v1/custom_emojis
  Future<List<Map<String, dynamic>>> getCustomEmojis() async {
    final response = await dio.get('/api/v1/custom_emojis');
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// GET /api/v1/timelines/tag/:hashtag
  Future<List<MastodonStatus>> getTagTimeline(
    String hashtag, {
    String? maxId,
    String? sinceId,
    int? limit,
    List<String>? all,
  }) async {
    final response = await dio.get(
      '/api/v1/timelines/tag/${Uri.encodeComponent(hashtag)}',
      queryParameters: {
        'max_id': ?maxId,
        'since_id': ?sinceId,
        'limit': ?limit,
        if (all != null && all.isNotEmpty) 'all[]': all,
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

  /// GET /api/v1/lists/:id/accounts
  Future<List<MastodonAccount>> getListAccounts(String listId) async {
    final response = await dio.get('/api/v1/lists/$listId/accounts');
    return (response.data as List)
        .map((e) => MastodonAccount.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/v1/lists/:id/accounts
  Future<void> addListAccounts(String listId, List<String> accountIds) async {
    await dio.post(
      '/api/v1/lists/$listId/accounts',
      data: {'account_ids': accountIds},
    );
  }

  /// DELETE /api/v1/lists/:id/accounts
  Future<void> removeListAccounts(
    String listId,
    List<String> accountIds,
  ) async {
    await dio.delete(
      '/api/v1/lists/$listId/accounts',
      data: {'account_ids': accountIds},
    );
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

  /// GET /api/v1/tags/:name
  Future<Map<String, dynamic>> getTag(String name) async {
    final response = await dio.get('/api/v1/tags/$name');
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/v1/tags/:name/follow
  Future<void> followTag(String name) async {
    await dio.post('/api/v1/tags/$name/follow');
  }

  /// POST /api/v1/tags/:name/unfollow
  Future<void> unfollowTag(String name) async {
    await dio.post('/api/v1/tags/$name/unfollow');
  }

  Future<void> votePoll(String pollId, List<int> choices) async {
    await dio.post('/api/v1/polls/$pollId/votes', data: {'choices': choices});
  }

  /// GET /api/v1/markers
  Future<Map<String, dynamic>> getMarkers(List<String> timelines) async {
    final response = await dio.get(
      '/api/v1/markers',
      queryParameters: {'timeline[]': timelines},
    );
    return response.data as Map<String, dynamic>;
  }

  /// GET /api/v1/instance
  Future<Map<String, dynamic>> getInstanceV1() async {
    final response = await dio.get('/api/v1/instance');
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/v1/statuses/:id/translate
  Future<Map<String, dynamic>> translateStatus(
    String statusId, {
    String? lang,
  }) async {
    final response = await dio.post(
      '/api/v1/statuses/$statusId/translate',
      data: lang != null ? FormData.fromMap({'lang': lang}) : null,
    );
    return response.data as Map<String, dynamic>;
  }

  /// GET /api/v2/instance
  Future<Map<String, dynamic>> getInstanceV2() async {
    final response = await dio.get('/api/v2/instance');
    return response.data as Map<String, dynamic>;
  }

  /// GET /health
  Future<String> checkHealth() async {
    final response = await dio.get('/health');
    return response.data.toString().trim();
  }

  /// GET /api/v1/streaming/health
  Future<String> checkStreamingHealth() async {
    final response = await dio.get('/api/v1/streaming/health');
    return response.data.toString().trim();
  }

  /// Probe whether the public timeline is accessible.
  /// Returns true if accessible, false if 403/401.
  Future<bool> probePublicTimeline({bool? local}) async {
    try {
      await dio.get(
        '/api/v1/timelines/public',
        queryParameters: {'local': ?local, 'limit': 1},
      );
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 403 || e.response?.statusCode == 401) {
        return false;
      }
      rethrow;
    }
  }

  /// PATCH /api/v1/accounts/update_credentials
  Future<MastodonAccount> updateCredentials({
    String? displayName,
    String? note,
    String? avatarPath,
    String? headerPath,
    List<Map<String, String>>? fieldsAttributes,
  }) async {
    Future<FormData> buildFormData() async {
      final map = <String, dynamic>{};
      if (displayName != null) map['display_name'] = displayName;
      if (note != null) map['note'] = note;
      if (avatarPath != null) {
        map['avatar'] = await MultipartFile.fromFile(avatarPath);
      }
      if (headerPath != null) {
        map['header'] = await MultipartFile.fromFile(headerPath);
      }
      if (fieldsAttributes != null) {
        for (var i = 0; i < fieldsAttributes.length; i++) {
          map['fields_attributes[$i][name]'] =
              fieldsAttributes[i]['name'] ?? '';
          map['fields_attributes[$i][value]'] =
              fieldsAttributes[i]['value'] ?? '';
        }
      }
      return FormData.fromMap(map);
    }

    final formData = await buildFormData();
    final response = await dio.patch(
      '/api/v1/accounts/update_credentials',
      data: formData,
      options: Options(
        extra: {RateLimitInterceptor.formDataFactoryKey: buildFormData},
      ),
    );
    return MastodonAccount.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/v1/markers
  Future<void> saveMarkers({
    String? homeLastReadId,
    String? notificationLastReadId,
  }) async {
    final data = <String, dynamic>{};
    if (homeLastReadId != null) {
      data['home'] = {'last_read_id': homeLastReadId};
    }
    if (notificationLastReadId != null) {
      data['notifications'] = {'last_read_id': notificationLastReadId};
    }
    try {
      await dio.post('/api/v1/markers', data: data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        // 409 Conflict is expected when concurrent marker updates race;
        // the server already has a newer marker, so we can safely ignore.
        return;
      }
      rethrow;
    }
  }
}

import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:fediverse_objects/fediverse_objects.dart';

import 'dart:developer' as developer;

import 'client.dart';
import 'extensions.dart';
import 'notification_streaming.dart';
import 'oauth_pkce.dart';
import 'streaming.dart';

/// Convert a list of items, skipping any that throw during conversion.
/// Returns the converted results, original item count, raw last ID, and
/// details of any items that failed conversion. [toRaw] を渡すと、変換に成功した
/// 要素の生 JSON を results と同じ並びで受け取れる（起動時キャッシュ用 / #890）。
({
  List<T> results,
  List<Map<String, dynamic>> raws,
  int rawCount,
  String? rawLastId,
  List<SkippedPost> skipped,
})
_safeConvert<S, T>(
  List<S> items,
  T Function(S) convert,
  String Function(S) getId, {
  Map<String, dynamic> Function(S)? toRaw,
}) {
  final results = <T>[];
  final raws = <Map<String, dynamic>>[];
  final skipped = <SkippedPost>[];
  for (final item in items) {
    try {
      // 起動時キャッシュ用の生 JSON は変換の前に作る (#890)。変換が落ちた要素は
      // results にも raws にも入らないので、両者の 1:1 が崩れない。
      final raw = toRaw?.call(item);
      results.add(convert(item));
      if (raw != null) raws.add(raw);
    } catch (e) {
      developer.log('skipping item during conversion: $e', name: 'capsicum');
      try {
        skipped.add(SkippedPost(id: getId(item), error: '$e'));
      } catch (_) {}
    }
  }
  return (
    results: results,
    raws: raws,
    rawCount: items.length,
    rawLastId: items.isNotEmpty ? getId(items.last) : null,
    skipped: skipped,
  );
}

class MastodonCapabilities extends AdapterCapabilities {
  Set<TimelineType> _supportedTimelines = {
    TimelineType.home,
    TimelineType.local,
    TimelineType.federated,
    TimelineType.directMessages,
  };

  @override
  Set<PostScope> get supportedScopes => {
    PostScope.public,
    PostScope.unlisted,
    PostScope.followersOnly,
    PostScope.direct,
  };

  @override
  Set<Formatting> get supportedFormattings => {Formatting.html};

  @override
  Set<TimelineType> get supportedTimelines => _supportedTimelines;

  set supportedTimelines(Set<TimelineType> value) =>
      _supportedTimelines = value;

  @override
  int? get maxPostContentLength => 500;
}

class MastodonAdapter extends DecentralizedBackendAdapter
    with
        FavoriteSupport,
        BookmarkSupport,
        AnnouncementSupport,
        AnnouncementReactionSupport,
        FollowSupport,
        NotificationSupport,
        SearchSupport,
        CustomEmojiSupport,
        ListSupport,
        HashtagSupport,
        PollSupport,
        LoginSupport,
        StreamSupport,
        NotificationStreamSupport,
        MarkerSupport,
        ProfileEditSupport,
        ReportSupport,
        PinSupport,
        PushSubscriptionSupport,
        ScheduleSupport,
        CollectionsSupport,
        TimelineCacheSupport,
        MulukhiyaRepostSupport,
        TranslationSupport {
  final MastodonClient client;
  MastodonStreaming? _streaming;
  MastodonNotificationStreaming? _notificationStreaming;
  bool _translationAvailable = false;

  /// 管理者ロール ID のセット（verify_credentials + モロヘイヤから学習）。
  final Set<String> _adminRoleIds = {};

  /// モロヘイヤの about API から取得した管理者ロール ID をマージする。
  void applyAdminRoleIds(List<String> ids) => _adminRoleIds.addAll(ids);

  @override
  final String host;

  @override
  final MastodonCapabilities capabilities = MastodonCapabilities();

  static const _scopes = ['read', 'write', 'follow', 'push'];

  /// Cached client credentials to reuse across login attempts.
  /// Set via [setCachedClientCredentials] before calling [startLogin].
  ClientSecretData? _cachedClientCredentials;

  /// Pre-set client credentials so [startLogin] can skip `POST /api/v1/apps`.
  void setCachedClientCredentials(ClientSecretData? credentials) {
    _cachedClientCredentials = credentials;
  }

  MastodonAdapter._(this.client, this.host);

  static Future<MastodonAdapter> create(String host) async {
    final client = MastodonClient(host);
    return MastodonAdapter._(client, host);
  }

  /// Detect which public timelines are available on this server.
  ///
  /// First tries Mastodon 4.5+ `timelines_access` from `/api/v2/instance`.
  /// Falls back to probing the public timeline API with 403 detection.
  Future<void> detectTimelineAvailability() async {
    var localEnabled = true;
    var federatedEnabled = true;

    try {
      // Try v2 instance API (Mastodon 4.5+).
      final instance = await client.getInstanceV2();
      final config = instance['configuration'] as Map<String, dynamic>?;
      final translation = config?['translation'] as Map<String, dynamic>?;
      _translationAvailable = translation?['enabled'] as bool? ?? false;
      final access = config?['timelines_access'] as Map<String, dynamic>?;
      if (access != null) {
        final liveFeeds = access['live_feeds'] as Map<String, dynamic>?;
        if (liveFeeds != null) {
          localEnabled = liveFeeds['local'] != 'disabled';
          federatedEnabled = liveFeeds['remote'] != 'disabled';
        }
      } else {
        // No timelines_access field — fall back to probing.
        localEnabled = await client.probePublicTimeline(local: true);
        federatedEnabled = await client.probePublicTimeline();
      }
    } catch (_) {
      // v2 instance API failed — fall back to probing.
      try {
        localEnabled = await client.probePublicTimeline(local: true);
        federatedEnabled = await client.probePublicTimeline();
      } catch (_) {
        // Probing also failed; keep defaults.
      }
    }

    capabilities.supportedTimelines = {
      TimelineType.home,
      if (localEnabled) TimelineType.local,
      if (federatedEnabled) TimelineType.federated,
      TimelineType.directMessages,
    };
  }

  // BackendAdapter

  @override
  FutureOr<void> applySecrets(
    ClientSecretData? clientSecret,
    UserSecret userSecret,
  ) {
    client.setAccessToken(userSecret.accessToken);
  }

  /// verify_credentials のレスポンスから管理者ロール ID を学習する。
  void _learnAdminRoles(MastodonAccount account) {
    // verify_credentials の role（単数形）に permissions が含まれる。
    final role = account.role;
    if (role != null) {
      final perms = int.tryParse(role['permissions']?.toString() ?? '') ?? 0;
      if ((perms & 0x1) != 0) {
        _adminRoleIds.add(role['id']?.toString() ?? '');
      }
    }
  }

  @override
  Future<User> getMyself() async {
    final account = await client.verifyCredentials();
    _learnAdminRoles(account);
    return account.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  @override
  Future<User?> getUser(String username, [String? remoteHost]) async {
    final acct = remoteHost != null ? '$username@$remoteHost' : username;
    final account = await client.lookupAccount(acct);
    return account?.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  @override
  Future<User> getUserById(String id) async {
    final account = await client.getAccount(id);
    return account.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  Future<List<Post>> getUserPosts(
    String id, {
    String? maxId,
    bool? onlyMedia,
    bool? excludeReplies,
  }) async {
    final statuses = await client.getAccountStatuses(
      id,
      maxId: maxId,
      limit: 20,
      onlyMedia: onlyMedia,
      excludeReplies: excludeReplies,
    );
    return _safeConvert(
      statuses,
      (s) => s.toCapsicum(host, adminRoleIds: _adminRoleIds),
      (s) => s.id,
    ).results;
  }

  Future<List<Post>> getPinnedPosts(String id) async {
    final statuses = await client.getAccountStatuses(id, pinned: true);
    return _safeConvert(
      statuses,
      (s) => s.toCapsicum(host, pinned: true),
      (s) => s.id,
    ).results;
  }

  /// モロヘイヤの再投稿レスポンスは `POST /api/v1/statuses` と同じ形で、
  /// **トップレベルがそのまま status**（mulukhiya#4491）。
  @override
  Post? parseRepostedPost(Map<String, dynamic> json) {
    try {
      return MastodonStatus.fromJson(json).toCapsicum(host);
    } catch (_) {
      // 版差で形が違っても、サーバー側では再投稿は成功している。素通しして
      // streaming / リフレッシュに委ねる。
      return null;
    }
  }

  @override
  Future<Post?> postStatus(PostDraft draft) async {
    if (draft.scheduledAt != null) {
      await client.scheduleStatus(
        status: draft.content ?? '',
        visibility: mastodonVisibilityFromScope(draft.scope),
        scheduledAt: draft.scheduledAt!.toUtc().toIso8601String(),
        inReplyToId: draft.inReplyToId,
        quoteId: draft.quoteId,
        spoilerText: draft.spoilerText,
        mediaIds: draft.mediaIds.isNotEmpty ? draft.mediaIds : null,
        sensitive: draft.sensitive ? true : null,
        language: draft.language,
        quoteApprovalPolicy: draft.quoteApprovalPolicy,
        extraHeaders: draft.skipMulukhiya ? {'X-Mulukhiya': 'capsicum'} : null,
      );
      return null;
    }
    try {
      final status = await client.postStatus(
        status: draft.content ?? '',
        visibility: mastodonVisibilityFromScope(draft.scope),
        inReplyToId: draft.inReplyToId,
        quoteId: draft.quoteId,
        spoilerText: draft.spoilerText,
        mediaIds: draft.mediaIds.isNotEmpty ? draft.mediaIds : null,
        sensitive: draft.sensitive ? true : null,
        language: draft.language,
        pollOptions: draft.pollOptions,
        pollExpiresIn: draft.pollExpiresIn,
        pollMultiple: draft.pollMultiple ? true : null,
        pollHideTotals: draft.pollHideTotals ? true : null,
        quoteApprovalPolicy: draft.quoteApprovalPolicy,
        extraHeaders: draft.skipMulukhiya ? {'X-Mulukhiya': 'capsicum'} : null,
      );
      return status.toCapsicum(host, adminRoleIds: _adminRoleIds);
    } on DioException {
      rethrow;
    } catch (_) {
      // The mulukhiya proxy may rewrite the response (e.g. NowPlaying
      // handler), making it unparseable. The post itself succeeded.
      return null;
    }
  }

  @override
  Future<List<ScheduledPost>> getScheduledPosts() async {
    return client.getScheduledStatuses();
  }

  @override
  Future<void> cancelScheduledPost(String id) async {
    await client.deleteScheduledStatus(id);
  }

  @override
  Future<void> deletePost(String id) async {
    await client.deleteStatus(id);
  }

  @override
  Future<TimelineResponse> getTimeline(
    TimelineType type, {
    TimelineQuery? query,
  }) async {
    // DM timeline uses conversation IDs for pagination, not status IDs.
    if (type == TimelineType.directMessages) {
      final result = await client.getConversations(
        maxId: query?.maxId,
        sinceId: query?.sinceId,
        limit: query?.limit,
      );
      final converted = _safeConvert(
        result.statuses,
        (s) => s.toCapsicum(host, adminRoleIds: _adminRoleIds),
        (s) => s.id,
      );
      return TimelineResponse(
        posts: converted.results,
        rawCount: converted.rawCount,
        rawLastId: result.lastConversationId,
        skippedPosts: converted.skipped,
      );
    }

    final statuses = switch (type) {
      TimelineType.home => await client.getHomeTimeline(
        maxId: query?.maxId,
        sinceId: query?.sinceId,
        minId: query?.minId,
        limit: query?.limit,
      ),
      TimelineType.local => await client.getPublicTimeline(
        local: true,
        maxId: query?.maxId,
        sinceId: query?.sinceId,
        limit: query?.limit,
      ),
      TimelineType.federated => await client.getPublicTimeline(
        maxId: query?.maxId,
        sinceId: query?.sinceId,
        limit: query?.limit,
      ),
      _ => throw UnimplementedError('Timeline type $type not supported'),
    };
    final converted = _safeConvert(
      statuses,
      (s) => s.toCapsicum(host, adminRoleIds: _adminRoleIds),
      (s) => s.id,
      toRaw: (s) => s.toJson(),
    );
    return TimelineResponse(
      posts: converted.results,
      rawCount: converted.rawCount,
      rawLastId: converted.rawLastId,
      skippedPosts: converted.skipped,
      rawJson: converted.raws,
    );
  }

  @override
  List<Post> decodeCachedPosts(List<Map<String, dynamic>> raw) {
    // 壊れた要素は捨てる。キャッシュは先出しの表示でしかなく、直後に REST の
    // 結果で置き換わるため、1 件でも読めれば得になる (#890)。
    return _safeConvert(
      raw,
      (json) => MastodonStatus.fromJson(
        json,
      ).toCapsicum(host, adminRoleIds: _adminRoleIds),
      (json) => '${json['id']}',
    ).results;
  }

  @override
  Future<Post> getPostById(String id) async {
    final status = await client.getStatus(id);
    return status.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  @override
  Future<List<Post>> getThread(String postId) async {
    final ctx = await client.getStatusContext(postId);
    final target = await client.getStatus(postId);
    return [
      ...ctx.ancestors.map(
        (s) => s.toCapsicum(host, adminRoleIds: _adminRoleIds),
      ),
      target.toCapsicum(host),
      ...ctx.descendants.map(
        (s) => s.toCapsicum(host, adminRoleIds: _adminRoleIds),
      ),
    ];
  }

  @override
  Future<Post> repeatPost(String id, {PostScope? visibility}) async {
    final status = await client.reblogStatus(
      id,
      visibility: visibility != null
          ? mastodonVisibilityRosetta.entries
                .firstWhere((e) => e.value == visibility)
                .key
          : null,
    );
    final post = status.toCapsicum(host, adminRoleIds: _adminRoleIds);
    return post.reblog ?? post;
  }

  @override
  Future<void> unrepeatPost(Post post) async {
    // Mastodon の /unreblog は「元 status の id」を要求する。
    // post が自分のブースト status の場合は post.reblog に元 status が入る。
    final originalId = post.reblog?.id ?? post.id;
    await client.unreblogStatus(originalId);
  }

  @override
  Future<Instance> getInstance() async {
    final foundedAt = await _fetchFoundedAt();
    try {
      return _parseInstanceV2(
        await client.getInstanceV2(),
        foundedAt: foundedAt,
      );
    } on DioException {
      return _parseInstanceV1(
        await client.getInstanceV1(),
        foundedAt: foundedAt,
      );
    }
  }

  /// 設立日 = 最初に作られたアカウント `accounts/1` の作成日 (#815 サーバー情報)。
  ///
  /// Mastodon のアカウント id は **2021-03 の timestamp_id 移行より前は連番**
  /// だったため、それ以前に開設された鯖には id=1（＝最初のローカルアカウント）が
  /// 残っており、その created_at が真の設立日になる（管理者が創立者と異なる 2 代目
  /// 管理人の鯖でも accounts/1 なら正しく取れる）。移行後に作られたアカウントは
  /// snowflake（大きな整数）id になるため、**近年フレッシュに開設された鯖では
  /// id=1 が存在せず 404** になる。その場合や凍結/削除時は null を返し、parse 側で
  /// contact_account（管理者・新規個人鯖では創立者と一致しがち）の作成日に
  /// フォールバックする。リモート（管理者権限なし）から「最古アカウント」を確実に
  /// 引く公開 API は無いため、これが実用的な最善。
  Future<DateTime?> _fetchFoundedAt() async {
    try {
      return (await client.getAccount('1')).createdAt;
    } catch (_) {
      // 設立日は付加情報。id=1 が無い(snowflake 世代)/凍結/削除でも
      // getInstance 本体を壊さない。
      return null;
    }
  }

  Instance _parseInstanceV2(Map<String, dynamic> data, {DateTime? foundedAt}) {
    final contact = data['contact'] as Map<String, dynamic>? ?? {};
    final config = data['configuration'] as Map<String, dynamic>? ?? {};
    final urls = config['urls'] as Map<String, dynamic>? ?? {};
    final media = config['media_attachments'] as Map<String, dynamic>? ?? {};
    final accountData = contact['account'] as Map<String, dynamic>?;
    User? contactAccount;
    if (accountData != null) {
      contactAccount = MastodonAccount.fromJson(
        accountData,
      ).toCapsicum(host, adminRoleIds: _adminRoleIds);
    }
    final rulesRaw = data['rules'] as List<dynamic>? ?? [];
    final rules = rulesRaw
        .map((r) => (r as Map<String, dynamic>)['text'] as String? ?? '')
        .where((t) => t.isNotEmpty)
        .toList();
    return Instance(
      name: data['title'] as String? ?? host,
      description: data['description'] as String?,
      iconUrl: _extractIconUrl(data),
      version: data['version'] as String?,
      themeColor:
          (config['accent_color'] as String?) ??
          (data['accent_color'] as String?),
      contactEmail: contact['email'] as String?,
      contactAccount: contactAccount,
      rules: rules,
      privacyPolicyUrl: 'https://$host/privacy-policy',
      statusUrl: urls['status'] as String?,
      foundedAt: foundedAt ?? contactAccount?.createdAt,
      imageSizeLimit: (media['image_size_limit'] as num?)?.toInt(),
      videoSizeLimit: (media['video_size_limit'] as num?)?.toInt(),
      audioSizeLimit: (media['audio_size_limit'] as num?)?.toInt(),
    );
  }

  Instance _parseInstanceV1(Map<String, dynamic> data, {DateTime? foundedAt}) {
    final contactData = data['contact_account'] as Map<String, dynamic>?;
    User? contactAccount;
    if (contactData != null) {
      contactAccount = MastodonAccount.fromJson(
        contactData,
      ).toCapsicum(host, adminRoleIds: _adminRoleIds);
    }
    final rulesRaw = data['rules'] as List<dynamic>? ?? [];
    final rules = rulesRaw
        .map((r) => (r as Map<String, dynamic>)['text'] as String? ?? '')
        .where((t) => t.isNotEmpty)
        .toList();

    return Instance(
      name: data['title'] as String? ?? host,
      description: data['description'] as String?,
      version: data['version'] as String?,
      contactEmail: data['email'] as String?,
      contactAccount: contactAccount,
      rules: rules,
      privacyPolicyUrl: 'https://$host/privacy-policy',
      foundedAt: foundedAt ?? contactAccount?.createdAt,
    );
  }

  String? _extractIconUrl(Map<String, dynamic> v2Data) {
    final icon = v2Data['icon'];
    if (icon is List && icon.isNotEmpty) {
      return (icon.first as Map<String, dynamic>)['src'] as String?;
    }
    if (icon is Map<String, dynamic>) {
      return icon['src'] as String?;
    }
    final thumbnail = v2Data['thumbnail'] as Map<String, dynamic>?;
    return thumbnail?['url'] as String?;
  }

  @override
  Future<Attachment> uploadAttachment(AttachmentDraft draft) async {
    var media = await client.uploadMedia(
      draft.filePath,
      mimeType: draft.mimeType,
    );
    if (draft.description != null && draft.description!.isNotEmpty) {
      media = await client.updateMedia(
        media.id,
        description: draft.description,
      );
    }
    return media.toCapsicum();
  }

  // LoginSupport

  @override
  Future<LoginResult> startLogin(ApplicationInfo application) async {
    try {
      String clientId;
      String clientSecret;

      final cached = _cachedClientCredentials;
      if (cached != null) {
        clientId = cached.clientId;
        clientSecret = cached.clientSecret;
      } else {
        // Register with both the custom scheme and OOB redirect URIs so
        // the OOB fallback can reuse the same client credentials.
        final redirectUris = [
          application.redirectUri.toString(),
          'urn:ietf:wg:oauth:2.0:oob',
        ].join('\n');
        final app = await client.createApplication(
          clientName: application.name,
          redirectUris: redirectUris,
          scopes: _scopes.join(' '),
          website: application.website?.toString(),
        );
        clientId = app.clientId!;
        clientSecret = app.clientSecret!;
      }

      // PKCE + state (#790)。loopback / カスタムスキーム callback への認可コード
      // 注入（同一端末の別アプリ/ページによる login-CSRF）を防ぐ。verifier は
      // extra に退避し token 交換で送る。state は callback 照合用に持ち回る。
      final pkce = OAuthPkceParams.generate();

      final authUrl = Uri.https(host, '/oauth/authorize', {
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': application.redirectUri.toString(),
        'scope': _scopes.join(' '),
        'force_login': 'true',
        'state': pkce.state,
        'code_challenge': pkce.codeChallenge,
        'code_challenge_method': OAuthPkceParams.codeChallengeMethod,
      });

      return LoginNeedsOAuth(
        authorizationUrl: authUrl,
        extra: {
          'client_id': clientId,
          'client_secret': clientSecret,
          'redirect_uri': application.redirectUri.toString(),
          'scopes': _scopes.join(' '),
          'state': pkce.state,
          'code_verifier': pkce.codeVerifier,
        },
      );
    } on DioException catch (e, s) {
      if (e.response?.statusCode == 429) {
        return LoginFailure('サーバーのアクセス制限に達しました。しばらく待ってから再試行してください', s);
      }
      return LoginFailure(e, s);
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
      // state 照合 (#790): 全プラットフォーム共通のバックストップ。startLogin で
      // 生成した state と callback の state が一致しなければ、別アプリ/別ページから
      // のコード注入（login-CSRF）とみなして token 交換に進まない。iOS カスタム
      // スキームや desktop の flutter_web_auth_2 経路（loopback server 側の照合が
      // 効かない経路）もここで守る。
      final expectedState = extra['state'];
      if (expectedState != null &&
          callbackUri.queryParameters['state'] != expectedState) {
        return LoginFailure(StateError('OAuth state mismatch'));
      }

      final code = callbackUri.queryParameters['code'];
      if (code == null) {
        return LoginFailure(StateError('No code in callback'));
      }

      final token = await client.getToken(
        grantType: 'authorization_code',
        clientId: extra['client_id']!,
        clientSecret: extra['client_secret']!,
        redirectUri: extra['redirect_uri']!,
        code: code,
        scope: extra['scopes'],
        codeVerifier: extra['code_verifier'],
      );

      client.setAccessToken(token.accessToken!);
      final account = await client.verifyCredentials();
      _learnAdminRoles(account);

      return LoginSuccess(
        userSecret: UserSecret(accessToken: token.accessToken!),
        clientSecret: ClientSecretData(
          clientId: extra['client_id']!,
          clientSecret: extra['client_secret']!,
        ),
        user: account.toCapsicum(host, adminRoleIds: _adminRoleIds),
      );
    } catch (e, s) {
      return LoginFailure(e, s);
    }
  }

  // FavoriteSupport

  @override
  Future<Post> favoritePost(String id) async {
    final status = await client.favouriteStatus(id);
    return status.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  @override
  Future<Post> unfavoritePost(String id) async {
    final status = await client.unfavouriteStatus(id);
    return status.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  // BookmarkSupport

  @override
  Future<Post> bookmarkPost(String id) async {
    final status = await client.bookmarkStatus(id);
    return status.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  @override
  Future<Post> unbookmarkPost(String id) async {
    final status = await client.unbookmarkStatus(id);
    return status.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  // PinSupport

  @override
  Future<Post> pinPost(String id) async {
    final status = await client.pinStatus(id);
    return status.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  @override
  Future<Post> unpinPost(String id) async {
    final status = await client.unpinStatus(id);
    return status.toCapsicum(host, adminRoleIds: _adminRoleIds);
  }

  @override
  Future<List<Post>> getBookmarks({TimelineQuery? query}) async {
    final statuses = await client.getBookmarks(
      maxId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
    );
    return _safeConvert(
      statuses,
      (s) => s.toCapsicum(host, adminRoleIds: _adminRoleIds),
      (s) => s.id,
    ).results;
  }

  // AnnouncementSupport

  @override
  Future<List<Announcement>> getAnnouncements() async {
    final announcements = await client.getAnnouncements();
    return announcements.reversed.map((a) => a.toCapsicum()).toList();
  }

  @override
  Future<void> dismissAnnouncement(String id) => client.dismissAnnouncement(id);

  @override
  Future<void> addAnnouncementReaction(String id, String name) =>
      client.putAnnouncementReaction(id, name);

  @override
  Future<void> removeAnnouncementReaction(String id, String name) =>
      client.deleteAnnouncementReaction(id, name);

  // FollowSupport

  @override
  Future<UserRelationship> getRelationship(String userId) async {
    final rels = await client.getRelationships([userId]);
    if (rels.isEmpty) return const UserRelationship();
    final r = rels.first;
    return UserRelationship(
      following: r['following'] as bool? ?? false,
      followedBy: r['followed_by'] as bool? ?? false,
      muting: r['muting'] as bool? ?? false,
      blocking: r['blocking'] as bool? ?? false,
      mutingExpiresAt: r['muting_expires_at'] is String
          ? DateTime.tryParse(r['muting_expires_at'] as String)
          : null,
    );
  }

  @override
  Future<void> followUser(String id) => client.followAccount(id);

  @override
  Future<void> unfollowUser(String id) => client.unfollowAccount(id);

  @override
  Future<void> muteUser(String id, {Duration? duration}) =>
      client.muteAccount(id, duration: duration?.inSeconds);

  @override
  Future<void> unmuteUser(String id) => client.unmuteAccount(id);

  @override
  Future<void> blockUser(String id) => client.blockAccount(id);

  @override
  Future<void> unblockUser(String id) => client.unblockAccount(id);

  @override
  Future<({List<User> users, String? nextCursor})> getFollowers(
    String userId, {
    TimelineQuery? query,
  }) async {
    final result = await client.getAccountFollowers(
      userId,
      maxId: query?.maxId,
      limit: query?.limit,
    );
    return (
      users: result.accounts
          .map((a) => a.toCapsicum(client.host, adminRoleIds: _adminRoleIds))
          .toList(),
      nextCursor: result.nextMaxId,
    );
  }

  @override
  Future<({List<User> users, String? nextCursor})> getFollowing(
    String userId, {
    TimelineQuery? query,
  }) async {
    final result = await client.getAccountFollowing(
      userId,
      maxId: query?.maxId,
      limit: query?.limit,
    );
    return (
      users: result.accounts
          .map((a) => a.toCapsicum(client.host, adminRoleIds: _adminRoleIds))
          .toList(),
      nextCursor: result.nextMaxId,
    );
  }

  Future<({List<User> users, String? nextCursor})> getFavouritedBy(
    String postId, {
    TimelineQuery? query,
  }) async {
    final result = await client.getFavouritedBy(
      postId,
      maxId: query?.maxId,
      limit: query?.limit,
    );
    return (
      users: result.accounts
          .map((a) => a.toCapsicum(client.host, adminRoleIds: _adminRoleIds))
          .toList(),
      nextCursor: result.nextMaxId,
    );
  }

  Future<({List<User> users, String? nextCursor})> getRebloggedBy(
    String postId, {
    TimelineQuery? query,
  }) async {
    final result = await client.getRebloggedBy(
      postId,
      maxId: query?.maxId,
      limit: query?.limit,
    );
    return (
      users: result.accounts
          .map((a) => a.toCapsicum(client.host, adminRoleIds: _adminRoleIds))
          .toList(),
      nextCursor: result.nextMaxId,
    );
  }

  // NotificationSupport

  @override
  Future<NotificationResponse> getNotifications({TimelineQuery? query}) async {
    final notifications = await client.getNotifications(
      maxId: query?.maxId,
      sinceId: query?.sinceId,
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
    final data = await client.search(
      query,
      resolve: isUrl ? true : null,
      limit: 20,
    );
    final accounts = (data['accounts'] as List? ?? [])
        .map((e) => MastodonAccount.fromJson(e as Map<String, dynamic>))
        .map((a) => a.toCapsicum(host, adminRoleIds: _adminRoleIds))
        .toList();
    final statuses = (data['statuses'] as List? ?? [])
        .map((e) => MastodonStatus.fromJson(e as Map<String, dynamic>))
        .map((s) => s.toCapsicum(host, adminRoleIds: _adminRoleIds))
        .toList();
    final hashtags = (data['hashtags'] as List? ?? [])
        .map((e) => (e as Map<String, dynamic>)['name'] as String)
        .toList();
    return SearchResults(users: accounts, posts: statuses, hashtags: hashtags);
  }

  @override
  Future<List<User>> searchUsers(String query, {int? limit}) async {
    final accounts = await client.searchAccounts(query, limit: limit);
    return accounts
        .map((a) => a.toCapsicum(host, adminRoleIds: _adminRoleIds))
        .toList();
  }

  @override
  Future<List<String>> searchHashtags(String query, {int? limit}) async {
    final data = await client.search(query, type: 'hashtags', limit: limit);
    return (data['hashtags'] as List? ?? [])
        .map((e) => (e as Map<String, dynamic>)['name'] as String)
        .toList();
  }

  // CustomEmojiSupport

  @override
  Future<List<CustomEmoji>> getEmojis() async {
    // visible_in_picker フィルタは picker 側に閉じ込めて、ここでは全件返す。
    // shortcode 警告判定 / プレビュー / sabacan 探索は picker 非表示の絵文字も
    // 投稿に使えるため、フィルタ済みリストを共有すると #609 警告で false
    // positive が出ていた (#622)。
    final emojis = await client.getCustomEmojis();
    return emojis
        .map(
          (e) => CustomEmoji(
            shortcode: e['shortcode'] as String,
            url: (e['static_url'] as String?) ?? (e['url'] as String?) ?? '',
            category: e['category'] as String?,
            visibleInPicker: e['visible_in_picker'] != false,
            featured: e['featured'] == true,
          ),
        )
        .toList();
  }

  // CollectionsSupport (Mastodon 4.6, FEP-7aa9, #722 / #742)

  /// index 応答は adapter によって `{ "collections": [...] }` で包まれる場合と
  /// 素の List の場合があるため defensive にアンラップする。
  List<Map<String, dynamic>> _collectionMapList(Object? data) {
    if (data is List) return data.whereType<Map<String, dynamic>>().toList();
    if (data is Map<String, dynamic> && data['collections'] is List) {
      return (data['collections'] as List)
          .whereType<Map<String, dynamic>>()
          .toList();
    }
    return const [];
  }

  /// 単体応答は `{ "<key>": {...} }` で包まれることも素のオブジェクトのことも
  /// あるためアンラップする。
  Map<String, dynamic> _unwrapMap(Object? data, String key) {
    if (data is Map<String, dynamic>) {
      final inner = data[key];
      if (inner is Map<String, dynamic>) return inner;
      return data;
    }
    return const {};
  }

  CollectionItem _collectionItemFromMap(Map<String, dynamic> m) =>
      CollectionItem(
        id: m['id']?.toString() ?? '',
        state: collectionItemStateFromString(m['state'] as String?),
        accountId: m['account_id']?.toString(),
      );

  Collection _collectionFromMap(Map<String, dynamic> m) {
    final itemsRaw = m['items'];
    return Collection(
      id: m['id']?.toString() ?? '',
      name: m['name'] as String? ?? '',
      url: m['url'] as String?,
      itemCount: (m['item_count'] as num?)?.toInt(),
      description: m['description'] as String?,
      ownerAccountId: m['account_id']?.toString(),
      discoverable: m['discoverable'] as bool?,
      sensitive: m['sensitive'] as bool?,
      tagName: (m['tag'] as Map<String, dynamic>?)?['name'] as String?,
      items: itemsRaw is List
          ? itemsRaw
                .whereType<Map<String, dynamic>>()
                .map(_collectionItemFromMap)
                .toList()
          : const [],
    );
  }

  @override
  Future<CollectionPage> getAccountCollections(
    String accountId, {
    int? offset,
  }) async {
    final page = await client.getAccountCollections(accountId, offset: offset);
    return (
      collections: _collectionMapList(
        page.data,
      ).map(_collectionFromMap).toList(),
      nextOffset: page.nextOffset,
    );
  }

  @override
  Future<CollectionPage> getInCollections(
    String accountId, {
    int? offset,
  }) async {
    final page = await client.getInCollections(accountId, offset: offset);
    return (
      collections: _collectionMapList(
        page.data,
      ).map(_collectionFromMap).toList(),
      nextOffset: page.nextOffset,
    );
  }

  @override
  Future<CollectionDetail> getCollection(String id) async {
    final data = await client.getCollection(id);
    final collectionMap = data['collection'] as Map<String, dynamic>? ?? data;
    final accountsRaw = data['accounts'];
    final accounts = accountsRaw is List
        ? accountsRaw
              .whereType<Map<String, dynamic>>()
              .map(
                (a) => MastodonAccount.fromJson(
                  a,
                ).toCapsicum(host, adminRoleIds: _adminRoleIds),
              )
              .toList()
        : <User>[];
    return CollectionDetail(
      collection: _collectionFromMap(collectionMap),
      accounts: accounts,
    );
  }

  @override
  Future<Collection> createCollection({
    required String name,
    String? description,
    String? tagName,
    bool? discoverable,
    bool? sensitive,
    List<String> accountIds = const [],
  }) async {
    final body = <String, dynamic>{'name': name};
    if (description != null) body['description'] = description;
    if (tagName != null) body['tag_name'] = tagName;
    if (discoverable != null) body['discoverable'] = discoverable;
    if (sensitive != null) body['sensitive'] = sensitive;
    if (accountIds.isNotEmpty) body['account_ids'] = accountIds;
    final data = await client.createCollection(body);
    return _collectionFromMap(_unwrapMap(data, 'collection'));
  }

  @override
  Future<Collection> updateCollection(
    String id, {
    String? name,
    String? description,
    String? tagName,
    bool? discoverable,
    bool? sensitive,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (description != null) body['description'] = description;
    if (tagName != null) body['tag_name'] = tagName;
    if (discoverable != null) body['discoverable'] = discoverable;
    if (sensitive != null) body['sensitive'] = sensitive;
    final data = await client.updateCollection(id, body);
    return _collectionFromMap(_unwrapMap(data, 'collection'));
  }

  @override
  Future<void> deleteCollection(String id) => client.deleteCollection(id);

  @override
  Future<CollectionItem> addCollectionItem(
    String collectionId,
    String accountId,
  ) async {
    final data = await client.addCollectionItem(collectionId, accountId);
    return _collectionItemFromMap(_unwrapMap(data, 'collection_item'));
  }

  @override
  Future<void> removeCollectionItem(String collectionId, String itemId) =>
      client.removeCollectionItem(collectionId, itemId);

  @override
  Future<void> revokeCollectionItem(String collectionId, String itemId) =>
      client.revokeCollectionItem(collectionId, itemId);

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
    final statuses = await client.getListTimeline(
      listId,
      maxId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
    );
    return _safeConvert(
      statuses,
      (s) => s.toCapsicum(host, adminRoleIds: _adminRoleIds),
      (s) => s.id,
    ).results;
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
    final accounts = await client.getListAccounts(listId);
    return accounts
        .map((a) => a.toCapsicum(host, adminRoleIds: _adminRoleIds))
        .toList();
  }

  @override
  Future<void> addListAccounts(String listId, List<String> accountIds) async {
    // Mastodon (pre-4.2) requires following accounts before adding to a list.
    // Follow any unfollowed accounts first.
    final rels = await client.getRelationships(accountIds);
    for (final rel in rels) {
      if (rel['following'] != true) {
        await client.followAccount(rel['id'] as String);
      }
    }
    await client.addListAccounts(listId, accountIds);
  }

  @override
  Future<void> removeListAccounts(
    String listId,
    List<String> accountIds,
  ) async {
    await client.removeListAccounts(listId, accountIds);
  }

  // MarkerSupport

  @override
  Future<MarkerSet> getMarkers() async {
    final data = await client.getMarkers(['home', 'notifications']);
    return MarkerSet(
      home: _parseMarker(data['home'] as Map<String, dynamic>?),
      notifications: _parseMarker(
        data['notifications'] as Map<String, dynamic>?,
      ),
    );
  }

  Marker? _parseMarker(Map<String, dynamic>? data) {
    if (data == null) return null;
    return Marker(
      lastReadId: data['last_read_id'] as String,
      version: data['version'] as int,
      updatedAt: DateTime.parse(data['updated_at'] as String),
    );
  }

  @override
  Future<void> saveHomeMarker(String lastReadId) async {
    await client.saveMarkers(homeLastReadId: lastReadId);
  }

  @override
  Future<void> saveNotificationMarker(String lastReadId) async {
    await client.saveMarkers(notificationLastReadId: lastReadId);
  }

  // HashtagSupport

  @override
  Future<bool> isFollowingHashtag(String hashtag) async {
    final data = await client.getTag(hashtag);
    return data['following'] as bool? ?? false;
  }

  @override
  Future<void> followHashtag(String hashtag) => client.followTag(hashtag);

  @override
  Future<void> unfollowHashtag(String hashtag) => client.unfollowTag(hashtag);

  @override
  Future<List<Post>> getPostsByHashtag(
    String hashtag, {
    TimelineQuery? query,
    List<String>? all,
  }) async {
    final statuses = await client.getTagTimeline(
      hashtag,
      maxId: query?.maxId,
      sinceId: query?.sinceId,
      limit: query?.limit,
      all: all,
    );
    return _safeConvert(
      statuses,
      (s) => s.toCapsicum(host, adminRoleIds: _adminRoleIds),
      (s) => s.id,
    ).results;
  }

  // PollSupport

  @override
  Future<void> votePoll(String pollId, List<int> choices) async {
    await client.votePoll(pollId, choices);
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
    // DM timeline has no dedicated stream; avoid falling back to 'user'
    // which would mix non-DM posts into the DM tab.
    if (type == TimelineType.directMessages) return const Stream.empty();
    final token = client.accessToken;
    if (token == null) return const Stream.empty();
    _streaming = MastodonStreaming(
      host: host,
      accessToken: token,
      adminRoleIds: _adminRoleIds,
      onParseError: onParseError,
      onStreamError: onStreamError,
      onReconnectExhausted: onReconnectExhausted,
      onConnectionState: onConnectionState,
      onDisconnect: onDisconnect,
    );
    return _streaming!.connect(type);
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
    _notificationStreaming = MastodonNotificationStreaming(
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

  // ProfileEditSupport

  @override
  Future<int?> getMaxProfileFields() async {
    // 補足情報の件数上限はクライアント仕様にハードコードしない（フォーク差を尊重。
    // 本家は DEFAULT_FIELDS_SIZE=10、4 に絞ったフォークもある）。
    //
    // 注意: 本家 Mastodon は上限件数を **どの instance API でも露出しない**
    // （v1/v2 とも accounts に max_profile_fields は存在しない。実体は
    // Account::DEFAULT_FIELDS_SIZE でサーバー内部値）。そのため通常は null になり、
    // 呼び出し側はクライアント側の件数強制をせずサーバーの検証 (422) に委ねる。
    // 将来フォークが v2 の configuration.accounts に上限を露出した場合のみ拾えるよう
    // v2 を試しておく（露出が無ければ null）。
    try {
      final instance = await client.getInstanceV2();
      final config = instance['configuration'] as Map<String, dynamic>?;
      final accounts = config?['accounts'] as Map<String, dynamic>?;
      return accounts?['max_profile_fields'] as int?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<User> updateProfile({
    String? displayName,
    String? description,
    String? avatarFilePath,
    String? bannerFilePath,
    List<UserField>? fields,
    bool removeAvatar = false,
    bool removeHeader = false,
    bool? locked,
    bool? discoverable,
  }) async {
    var account = await client.updateCredentials(
      displayName: displayName,
      note: description,
      avatarPath: avatarFilePath,
      headerPath: bannerFilePath,
      fieldsAttributes: fields
          ?.map((f) => {'name': f.name, 'value': f.value})
          .toList(),
      locked: locked,
      discoverable: discoverable,
    );
    // 画像削除は update_credentials では表現できないため 4.6 の destroy
    // エンドポイントで行い、最新の account を返す（#736）。差し替えとは排他。
    // 本文更新は上で成功済みなので、削除ステップの失敗はまとめて捕捉し、
    // 部分成功として呼び出し側に返す（全失敗表示にしない、#806）。
    final failedSteps = <String>[];
    Object? firstError;
    StackTrace? firstStack;
    if (removeAvatar) {
      try {
        account = await client.deleteProfileAvatar();
      } catch (e, st) {
        failedSteps.add('avatar_remove');
        firstError ??= e;
        firstStack ??= st;
      }
    }
    if (removeHeader) {
      try {
        account = await client.deleteProfileHeader();
      } catch (e, st) {
        failedSteps.add('header_remove');
        firstError ??= e;
        firstStack ??= st;
      }
    }
    final user = account.toCapsicum(host, adminRoleIds: _adminRoleIds);
    if (failedSteps.isNotEmpty) {
      throw ProfileUpdatePartialException(
        user: user,
        failedSteps: failedSteps,
        cause: firstError!,
        stackTrace: firstStack!,
      );
    }
    return user;
  }

  @override
  bool get supportsProfileImageRemoval => true;

  // ReportSupport

  @override
  Future<void> reportPost(
    String postId,
    String authorId, {
    String? comment,
  }) async {
    await client.createReport(authorId, statusIds: [postId], comment: comment);
  }

  @override
  Future<void> reportUser(String userId, {String? comment}) async {
    // status_ids を省くと「アカウントに対する通報」になる。空配列ではなく
    // 未送信にする必要がある (#998)。
    await client.createReport(userId, comment: comment);
  }

  // TranslationSupport

  bool get isTranslationAvailable => _translationAvailable;

  @override
  Future<TranslationResult> translatePost(
    String postId, {
    String? targetLang,
  }) async {
    final data = await client.translateStatus(postId, lang: targetLang);
    return TranslationResult(
      content: data['content'] as String? ?? '',
      detectedLanguage: data['detected_source_language'] as String?,
      provider: data['provider'] as String?,
    );
  }

  // -- PushSubscriptionSupport --

  @override
  Future<String?> getVapidPublicKey() async {
    try {
      final data = await client.getInstanceV2();
      return (data['configuration'] as Map?)?['vapid']?['public_key']
          as String?;
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
    return client.subscribePush(endpoint: endpoint, p256dh: p256dh, auth: auth);
  }

  @override
  Future<void> unsubscribePush({String? endpoint}) async {
    // endpoint は Misskey 用。Mastodon の DELETE /api/v1/push/subscription は
    // 現 OAuth トークンのサブスクリプションを対象とするため引数では絞れない。
    // 将来 endpoint を使いたくなった際に「実は無視していた」ことを失念しない
    // よう、非 null が来たら開発ビルドで気付けるよう debugPrint で警告する。
    if (endpoint != null) {
      developer.log(
        'MastodonAdapter.unsubscribePush ignores endpoint: $endpoint',
        name: 'capsicum',
      );
    }
    await client.unsubscribePush();
  }
}

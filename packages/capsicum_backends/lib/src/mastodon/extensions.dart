import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';

const mastodonVisibilityRosetta = <String, PostScope>{
  'public': PostScope.public,
  'unlisted': PostScope.unlisted,
  'private': PostScope.followersOnly,
  'direct': PostScope.direct,
};

String mastodonVisibilityFromScope(PostScope scope) =>
    mastodonVisibilityRosetta.entries.firstWhere((e) => e.value == scope).key;

const mastodonAttachmentTypeMap = <String, AttachmentType>{
  'image': AttachmentType.image,
  'video': AttachmentType.video,
  'audio': AttachmentType.audio,
  'gifv': AttachmentType.gifv,
  'unknown': AttachmentType.unknown,
};

extension CapsicumMastodonAccountExtension on MastodonAccount {
  User toCapsicum(String localHost, {Set<String> adminRoleIds = const {}}) {
    final atHost = acct.contains('@') ? acct.split('@').last : null;
    return User(
      id: id,
      username: username,
      displayName: displayName.isEmpty ? null : displayName,
      host: atHost ?? localHost,
      avatarUrl: avatar,
      bannerUrl: header,
      avatarDescription: avatarDescription,
      bannerDescription: headerDescription,
      description: note,
      followersCount: followersCount,
      followingCount: followingCount,
      postCount: statusesCount,
      isBot: bot ?? false,
      // 標準 Mastodon API の `group` boolean を優先。`actor_type` は REST
      // シリアライザが公開しないためフォーク独自経路のフォールバック (#726)。
      isGroup: (group ?? false) || actorType == 'Group',
      roles: (roles ?? []).map((r) {
        final roleId = r['id']?.toString() ?? '';
        final perms = int.tryParse(r['permissions']?.toString() ?? '') ?? 0;
        return UserRole(
          id: roleId,
          name: r['name'] as String? ?? '',
          color: r['color'] as String?,
          isAdmin: (perms & 0x1) != 0 || adminRoleIds.contains(roleId),
        );
      }).toList(),
      fields: fields
          .map(
            (f) => UserField(
              name: f['name'] as String? ?? '',
              value: f['value'] as String? ?? '',
              verifiedAt: f['verified_at'] != null
                  ? DateTime.tryParse(f['verified_at'] as String)
                  : null,
            ),
          )
          .toList(),
      emojis: {
        for (final e in emojis ?? [])
          if (e['shortcode'] is String && e['url'] is String)
            e['shortcode'] as String: e['url'] as String,
      },
      url: url,
      createdAt: createdAt,
      defaultScope: mastodonVisibilityRosetta[source?['privacy'] as String?],
      showMedia: showMedia,
      showMediaReplies: showMediaReplies,
      showFeatured: showFeatured,
      hideCollections: hideCollections,
      featureApproval: _parseFeatureApproval(featureApproval),
      locked: locked,
      discoverable: discoverable,
      movedTo: _movedTo(moved),
    );
  }
}

/// `moved`（入れ子の Account）から引っ越し先を組む (#1055)。
///
/// ⚠ **`url` が無い `moved` は捨てる。**遷移先が作れず、画面に出しても「引っ越し
/// ました」だけで行き先が示せないため。`acct` があれば `@user@host` を作る
/// （`acct` はリモートなら既に `user@host` の形）。
MovedTo? _movedTo(MastodonAccount? moved) {
  if (moved == null) return null;
  final url = moved.url;
  if (url == null || url.isEmpty) return null;
  return MovedTo(url: url, handle: '@${moved.acct}', userId: moved.id);
}

FeatureApproval? _parseFeatureApproval(Map<String, dynamic>? raw) {
  if (raw == null) return null;
  List<String> keys(Object? v) =>
      v is List ? v.map((e) => e.toString()).toList() : const <String>[];
  return FeatureApproval(
    automatic: keys(raw['automatic']),
    manual: keys(raw['manual']),
    currentUser: raw['current_user']?.toString(),
  );
}

extension CapsicumMastodonStatusExtension on MastodonStatus {
  Post toCapsicum(
    String localHost, {
    bool pinned = false,
    Set<String> adminRoleIds = const {},
  }) {
    final filterResult = _parseFilterResult(filtered);
    final quoteResult = _parseQuoteResult(
      quote,
      localHost,
      adminRoleIds: adminRoleIds,
    );
    return Post(
      id: id,
      postedAt: createdAt,
      author: account.toCapsicum(localHost, adminRoleIds: adminRoleIds),
      content: content,
      isHtml: true,
      scope: mastodonVisibilityRosetta[visibility] ?? PostScope.public,
      attachments: mediaAttachments.map((a) => a.toCapsicum()).toList(),
      favouriteCount: favouritesCount,
      reblogCount: reblogsCount,
      replyCount: repliesCount,
      quoteCount: quotesCount ?? 0,
      favourited: favourited ?? false,
      reblogged: reblogged ?? false,
      bookmarked: bookmarked ?? false,
      sensitive: sensitive ?? false,
      inReplyToId: inReplyToId,
      reblog: reblog?.toCapsicum(localHost, adminRoleIds: adminRoleIds),
      quote: quoteResult?.post,
      quoteState: quoteResult?.state,
      spoilerText: spoilerText?.isNotEmpty == true ? spoilerText : null,
      emojis: {
        ..._extractHtmlCustomEmojis(content),
        for (final e in emojis ?? [])
          if (e['shortcode'] is String &&
              (e['url'] is String || e['static_url'] is String))
            e['shortcode'] as String:
                (e['url'] as String?) ?? (e['static_url'] as String),
      },
      card: _parseCard(card),
      poll: _parseMastodonPoll(poll),
      filterAction: filterResult?.action,
      filterTitle: filterResult?.title,
      pinned: pinned,
      quotable: _isQuotable(quoteApproval),
      quoteApprovalPolicy: parseMastodonQuoteApprovalPolicy(quoteApproval),
      language: language,
      url: url,
      editedAt: editedAt,
    );
  }
}

/// 投稿者が設定した引用許可を、投稿時の `quote_approval_policy` の値へ戻す
/// (#1113)。削除して再編集で元の設定を引き継ぐのに使う。
///
/// `quote_approval.automatic` はフラグ名の配列（`InteractionPolicy::POLICY_FLAGS`）
/// で、Mastodon の API から付けられるのは `public` / `followers` / 空（＝`nobody`）
/// の 3 通り。Mastodon WebUI の REDRAFT も `automatic[0] || 'nobody'` で読む。
///
/// ⚠ **知らないフラグだけのときは `nobody` へ倒す。**再編集で許可を**広げない**
/// ほうが安全（広がっても画面からは気づけない）。WebUI の `automatic[0]` は
/// 先頭が `unsupported_policy` だとそれを返すので、ここは真似ない。
///
/// `quote_approval` 自体が無いサーバー（4.5 未満）は null ＝何も送らない。
String? parseMastodonQuoteApprovalPolicy(Map<String, dynamic>? quoteApproval) {
  if (quoteApproval == null) return null;
  final raw = quoteApproval['automatic'];
  final automatic = raw is List
      ? raw.map((e) => e.toString()).toSet()
      : const <String>{};
  if (automatic.contains('public')) return 'public';
  if (automatic.contains('followers')) return 'followers';
  return 'nobody';
}

bool _isQuotable(Map<String, dynamic>? quoteApproval) {
  if (quoteApproval == null) return true;
  final currentUser = quoteApproval['current_user'] as String?;
  // ホワイトリスト方式: 明示的な許可値のみ引用可能とする
  // unknown やその他の未知の値は引用不可として扱う (#205)
  return currentUser == null ||
      currentUser == 'automatic' ||
      currentUser == 'manual';
}

({Post? post, QuoteState? state})? _parseQuoteResult(
  Object? quoteRaw,
  String localHost, {
  Set<String> adminRoleIds = const {},
}) {
  if (quoteRaw == null) return null;
  if (quoteRaw is! Map<String, dynamic>) return null;

  // Parse state from Mastodon 4.5 quote object.
  final stateStr = quoteRaw['state'] as String?;
  final quoteState = switch (stateStr) {
    'pending' => QuoteState.pending,
    'accepted' => QuoteState.accepted,
    'rejected' => QuoteState.rejected,
    'deleted' => QuoteState.deleted,
    'unauthorized' => QuoteState.unauthorized,
    _ => null,
  };

  // Mastodon latest: quote is { "state": "...", "quoted_status": {...} }
  // Use quoted_status if present (regardless of state — "pending" also has data).
  // If the object has a "state" key but no "quoted_status", return state only.
  // Otherwise treat quoteRaw itself as a status object (older format fallback).
  final Map<String, dynamic>? quote;
  if (quoteRaw.containsKey('quoted_status')) {
    quote = quoteRaw['quoted_status'] as Map<String, dynamic>?;
  } else if (quoteRaw.containsKey('state')) {
    return (post: null, state: quoteState);
  } else {
    quote = quoteRaw;
  }
  if (quote == null) return (post: null, state: quoteState);
  final id = quote['id'] as String?;
  final account = quote['account'] as Map<String, dynamic>?;
  if (id == null || account == null) return (post: null, state: quoteState);
  final username = account['username'] as String? ?? '';
  final acct = account['acct'] as String? ?? username;
  final atHost = acct.contains('@') ? acct.split('@').last : null;
  final emojis = account['emojis'] as List<dynamic>? ?? [];
  final postEmojis = quote['emojis'] as List<dynamic>? ?? [];
  return (
    post: Post(
      id: id,
      postedAt:
          DateTime.tryParse(quote['created_at'] as String? ?? '') ??
          DateTime.now(),
      author: User(
        id: account['id'] as String? ?? '',
        username: username,
        displayName: (account['display_name'] as String?)?.isNotEmpty == true
            ? account['display_name'] as String
            : null,
        host: atHost ?? localHost,
        avatarUrl: account['avatar'] as String?,
        emojis: {
          for (final e in emojis)
            if (e is Map<String, dynamic> &&
                e['shortcode'] is String &&
                e['url'] is String)
              e['shortcode'] as String: e['url'] as String,
        },
      ),
      content: quote['content'] as String? ?? '',
      isHtml: true,
      spoilerText: (quote['spoiler_text'] as String?)?.isNotEmpty == true
          ? quote['spoiler_text'] as String
          : null,
      scope:
          mastodonVisibilityRosetta[quote['visibility'] as String?] ??
          PostScope.public,
      attachments: ((quote['media_attachments'] as List<dynamic>?) ?? [])
          .whereType<Map<String, dynamic>>()
          .map(
            (a) => Attachment(
              id: a['id'] as String? ?? '',
              type:
                  mastodonAttachmentTypeMap[a['type'] as String?] ??
                  AttachmentType.unknown,
              url: a['url'] as String? ?? '',
              previewUrl: a['preview_url'] as String?,
              description: a['description'] as String?,
            ),
          )
          .toList(),
      emojis: {
        for (final e in postEmojis)
          if (e is Map<String, dynamic> &&
              e['shortcode'] is String &&
              e['url'] is String)
            e['shortcode'] as String: e['url'] as String,
      },
    ),
    state: quoteState ?? QuoteState.accepted,
  );
}

Poll? _parseMastodonPoll(Map<String, dynamic>? poll) {
  if (poll == null) return null;
  final id = poll['id'] as String?;
  final options = poll['options'] as List<dynamic>?;
  if (id == null || options == null) return null;
  final expiresAtStr = poll['expires_at'] as String?;
  final emojis = poll['emojis'] as List<dynamic>? ?? [];
  return Poll(
    id: id,
    options: options
        .map(
          (o) => PollOption(
            title: (o as Map<String, dynamic>)['title'] as String? ?? '',
            votesCount: o['votes_count'] as int? ?? 0,
          ),
        )
        .toList(),
    votersCount: poll['voters_count'] as int? ?? 0,
    multiple: poll['multiple'] as bool? ?? false,
    expired: poll['expired'] as bool? ?? false,
    expiresAt: expiresAtStr != null ? DateTime.tryParse(expiresAtStr) : null,
    voted: poll['voted'] as bool? ?? false,
    ownVotes:
        (poll['own_votes'] as List<dynamic>?)?.map((v) => v as int).toList() ??
        const [],
    emojis: {
      for (final e in emojis)
        if (e is Map<String, dynamic> &&
            e['shortcode'] is String &&
            e['url'] is String)
          e['shortcode'] as String: e['url'] as String,
    },
  );
}

PreviewCard? _parseCard(Map<String, dynamic>? card) {
  if (card == null) return null;
  final url = card['url'] as String?;
  final title = card['title'] as String?;
  if (url == null || title == null || title.isEmpty) return null;
  return PreviewCard(
    url: url,
    title: title,
    description: card['description'] as String?,
    imageUrl: card['image'] as String?,
  );
}

({FilterAction action, String? title})? _parseFilterResult(
  List<Map<String, dynamic>>? filtered,
) {
  if (filtered == null || filtered.isEmpty) return null;
  FilterAction action = FilterAction.warn;
  String? title;
  for (final entry in filtered) {
    final filter = entry['filter'] as Map<String, dynamic>?;
    if (filter == null) continue;
    final filterAction = filter['filter_action'] as String?;
    title ??= filter['title'] as String?;
    if (filterAction == 'hide') {
      return (action: FilterAction.hide, title: title);
    }
  }
  return (action: action, title: title);
}

const mastodonNotificationTypeMap = <String, NotificationType>{
  'mention': NotificationType.mention,
  'reblog': NotificationType.reblog,
  'favourite': NotificationType.favourite,
  'follow': NotificationType.follow,
  'follow_request': NotificationType.followRequest,
  'poll': NotificationType.poll,
  'update': NotificationType.update,
  // Mastodon 4.6 Collections (FEP-7aa9) の被フィーチャー通知 (#741)。
  'added_to_collection': NotificationType.addedToCollection,
  'collection_update': NotificationType.collectionUpdate,
};

extension CapsicumMastodonNotificationExtension on MastodonNotification {
  Notification toCapsicum(
    String localHost, {
    Set<String> adminRoleIds = const {},
  }) {
    return Notification(
      id: id,
      type: mastodonNotificationTypeMap[type] ?? NotificationType.other,
      createdAt: createdAt,
      user: account.toCapsicum(localHost, adminRoleIds: adminRoleIds),
      post: status?.toCapsicum(localHost, adminRoleIds: adminRoleIds),
      collection: collection?.toCapsicum(),
    );
  }
}

extension CapsicumMastodonCollectionExtension on MastodonCollection {
  Collection toCapsicum() =>
      Collection(id: id, name: name, url: url, itemCount: itemCount);
}

extension CapsicumMastodonAnnouncementExtension on MastodonAnnouncement {
  Announcement toCapsicum() {
    return Announcement(
      id: id,
      content: content,
      publishedAt: publishedAt,
      read: read,
      isHtml: true,
      reactions: reactions.map((r) => r.toCapsicum()).toList(),
    );
  }
}

extension CapsicumMastodonAnnouncementReactionExtension
    on MastodonAnnouncementReaction {
  AnnouncementReaction toCapsicum() {
    return AnnouncementReaction(name: name, count: count, me: me, url: url);
  }
}

Map<String, String> _extractHtmlCustomEmojis(String html) {
  final map = <String, String>{};
  final imgRegex = RegExp(r'<img[^>]+>');
  for (final match in imgRegex.allMatches(html)) {
    final img = match.group(0)!;
    final altMatch = RegExp(r'alt=":([a-zA-Z0-9_-]+):"').firstMatch(img);
    final srcMatch = RegExp(r'src="([^"]+)"').firstMatch(img);
    if (altMatch != null && srcMatch != null) {
      map[altMatch.group(1)!] = srcMatch.group(1)!;
    }
  }
  return map;
}

extension CapsicumMastodonListExtension on MastodonList {
  PostList toCapsicum() {
    return PostList(id: id, title: title);
  }
}

extension CapsicumMastodonMediaAttachmentExtension on MastodonMediaAttachment {
  Attachment toCapsicum() {
    return Attachment(
      id: id,
      type: mastodonAttachmentTypeMap[type] ?? AttachmentType.unknown,
      url: url ?? '',
      previewUrl: previewUrl,
      description: description,
    );
  }
}

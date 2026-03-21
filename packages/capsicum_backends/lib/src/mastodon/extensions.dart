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
      description: note,
      followersCount: followersCount,
      followingCount: followingCount,
      postCount: statusesCount,
      isBot: bot ?? false,
      isGroup: actorType == 'Group',
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
            ),
          )
          .toList(),
      emojis: {
        for (final e in emojis ?? [])
          if (e['shortcode'] is String && e['url'] is String)
            e['shortcode'] as String: e['url'] as String,
      },
    );
  }
}

extension CapsicumMastodonStatusExtension on MastodonStatus {
  Post toCapsicum(
    String localHost, {
    bool pinned = false,
    Set<String> adminRoleIds = const {},
  }) {
    final filterResult = _parseFilterResult(filtered);
    return Post(
      id: id,
      postedAt: createdAt,
      author: account.toCapsicum(localHost, adminRoleIds: adminRoleIds),
      content: content,
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
      quote: _parseQuote(quote, localHost, adminRoleIds: adminRoleIds),
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
    );
  }
}

Post? _parseQuote(
  Object? quoteRaw,
  String localHost, {
  Set<String> adminRoleIds = const {},
}) {
  if (quoteRaw == null) return null;
  if (quoteRaw is! Map<String, dynamic>) return null;
  // Mastodon latest: quote is { "state": "...", "quoted_status": {...} }
  // Use quoted_status if present (regardless of state — "pending" also has data).
  // If the object has a "state" key but no "quoted_status", the quote is unavailable.
  // Otherwise treat quoteRaw itself as a status object (older format fallback).
  final Map<String, dynamic>? quote;
  if (quoteRaw.containsKey('quoted_status')) {
    quote = quoteRaw['quoted_status'] as Map<String, dynamic>?;
  } else if (quoteRaw.containsKey('state')) {
    return null;
  } else {
    quote = quoteRaw;
  }
  if (quote == null) return null;
  final id = quote['id'] as String?;
  final account = quote['account'] as Map<String, dynamic>?;
  if (id == null || account == null) return null;
  final username = account['username'] as String? ?? '';
  final acct = account['acct'] as String? ?? username;
  final atHost = acct.contains('@') ? acct.split('@').last : null;
  final emojis = account['emojis'] as List<dynamic>? ?? [];
  return Post(
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
    );
  }
}

extension CapsicumMastodonAnnouncementExtension on MastodonAnnouncement {
  Announcement toCapsicum() {
    return Announcement(
      id: id,
      content: content,
      publishedAt: publishedAt,
      read: read,
      isHtml: true,
    );
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

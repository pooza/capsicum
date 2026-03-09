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
  User toCapsicum(String localHost) {
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
  Post toCapsicum(String localHost) {
    final filterResult = _parseFilterResult(filtered);
    return Post(
      id: id,
      postedAt: createdAt,
      author: account.toCapsicum(localHost),
      content: content,
      scope: mastodonVisibilityRosetta[visibility] ?? PostScope.public,
      attachments: mediaAttachments.map((a) => a.toCapsicum()).toList(),
      favouriteCount: favouritesCount,
      reblogCount: reblogsCount,
      replyCount: repliesCount,
      favourited: favourited ?? false,
      reblogged: reblogged ?? false,
      bookmarked: bookmarked ?? false,
      sensitive: sensitive ?? false,
      inReplyToId: inReplyToId,
      reblog: reblog?.toCapsicum(localHost),
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
    );
  }
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
    expiresAt:
        expiresAtStr != null ? DateTime.tryParse(expiresAtStr) : null,
    voted: poll['voted'] as bool? ?? false,
    ownVotes: (poll['own_votes'] as List<dynamic>?)
            ?.map((v) => v as int)
            .toList() ??
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
  Notification toCapsicum(String localHost) {
    return Notification(
      id: id,
      type: mastodonNotificationTypeMap[type] ?? NotificationType.other,
      createdAt: createdAt,
      user: account.toCapsicum(localHost),
      post: status?.toCapsicum(localHost),
    );
  }
}

extension CapsicumMastodonAnnouncementExtension on MastodonAnnouncement {
  Announcement toCapsicum() {
    return Announcement(
      id: id,
      content: _stripHtml(content),
      publishedAt: publishedAt,
      read: read,
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

String _stripHtml(String html) {
  var text = html
      .replaceAll(RegExp(r'<br\s*/?>'), '\n')
      .replaceAll(RegExp(r'</p>\s*<p>'), '\n\n')
      .replaceAll(RegExp(r'<[^>]*>'), '');
  text = text
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.parse(m[1]!)),
      )
      .replaceAllMapped(
        RegExp(r'&#x([0-9a-fA-F]+);'),
        (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
      );
  return text;
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
      url: url,
      previewUrl: previewUrl,
      description: description,
    );
  }
}

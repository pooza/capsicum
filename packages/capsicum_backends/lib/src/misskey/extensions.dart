import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';

const misskeyVisibilityRosetta = <String, PostScope>{
  'public': PostScope.public,
  'home': PostScope.unlisted,
  'followers': PostScope.followersOnly,
  'specified': PostScope.direct,
};

String misskeyVisibilityFromScope(PostScope scope) =>
    misskeyVisibilityRosetta.entries.firstWhere((e) => e.value == scope).key;

extension CapsicumMisskeyUserExtension on MisskeyUser {
  User toCapsicum(String localHost, {Set<String> adminRoleIds = const {}}) {
    return User(
      id: id,
      username: username,
      displayName: name,
      host: host ?? localHost,
      avatarUrl: avatarUrl,
      bannerUrl: bannerUrl,
      description: description,
      followersCount: followersCount ?? 0,
      followingCount: followingCount ?? 0,
      postCount: notesCount ?? 0,
      isBot: isBot ?? false,
      roles: roles != null
          ? roles!
                .map(
                  (r) => UserRole(
                    id: r['id']?.toString() ?? '',
                    name: r['name'] as String? ?? '',
                    color: r['color'] as String?,
                    iconUrl: r['iconUrl'] as String?,
                    isAdmin:
                        (r['isAdministrator'] as bool? ?? false) ||
                        adminRoleIds.contains(r['id']?.toString() ?? ''),
                  ),
                )
                .toList()
          : (badgeRoles ?? [])
                .map(
                  (r) => UserRole(
                    id: '',
                    name: r['name'] as String? ?? '',
                    iconUrl: r['iconUrl'] as String?,
                  ),
                )
                .toList(),
      fields: (fields ?? []).map((f) {
        final value = f['value'] as String? ?? '';
        final verified = (verifiedLinks ?? []).contains(value);
        return UserField(
          name: f['name'] as String? ?? '',
          value: value,
          verifiedAt: verified ? DateTime.now() : null,
        );
      }).toList(),
      emojis: emojis ?? const {},
      avatarDecorations: (avatarDecorations ?? [])
          .map(
            (d) => AvatarDecoration(
              id: d['id'] as String? ?? '',
              url: d['url'] as String? ?? '',
              angle: (d['angle'] as num?)?.toDouble() ?? 0,
              flipH: d['flipH'] as bool? ?? false,
              offsetX: (d['offsetX'] as num?)?.toDouble() ?? 0,
              offsetY: (d['offsetY'] as num?)?.toDouble() ?? 0,
            ),
          )
          .where((d) => d.url.isNotEmpty)
          .toList(),
      url: 'https://${host ?? localHost}/@$username',
      createdAt: createdAt,
      defaultScope: misskeyVisibilityRosetta[defaultNoteVisibility],
    );
  }
}

extension CapsicumMisskeyNoteExtension on MisskeyNote {
  Post toCapsicum(
    String localHost, {
    bool pinned = false,
    Set<String> adminRoleIds = const {},
  }) {
    // Misskey: renote + text = quote, renote without text = simple renote
    final isQuote = renote != null && text != null;
    return Post(
      id: id,
      postedAt: createdAt,
      author: user.toCapsicum(localHost, adminRoleIds: adminRoleIds),
      content: text,
      scope: misskeyVisibilityRosetta[visibility] ?? PostScope.public,
      attachments: (files ?? []).map((f) => f.toCapsicum()).toList(),
      sensitive: (files ?? []).any((f) => f.isSensitive),
      reblogCount: renoteCount,
      replyCount: repliesCount,
      reactions: reactions ?? const {},
      myReaction: myReaction,
      reactionEmojis: reactionEmojis ?? const {},
      reblog: isQuote
          ? null
          : renote?.toCapsicum(localHost, adminRoleIds: adminRoleIds),
      quote: isQuote
          ? renote?.toCapsicum(localHost, adminRoleIds: adminRoleIds)
          : null,
      poll: _parseMisskeyPoll(poll, id),
      spoilerText: cw,
      emojis: {...?noteEmojis, ...?reactionEmojis},
      emojiHost: localHost,
      pinned: pinned,
      channelId: channel?['id'] as String?,
      channelName: channel?['name'] as String?,
      localOnly: localOnly ?? false,
      url: 'https://$localHost/notes/$id',
    );
  }
}

const misskeyNotificationTypeMap = <String, NotificationType>{
  'mention': NotificationType.mention,
  'reply': NotificationType.mention,
  'renote': NotificationType.reblog,
  'follow': NotificationType.follow,
  'receiveFollowRequest': NotificationType.followRequest,
  'reaction': NotificationType.reaction,
  'pollEnded': NotificationType.poll,
};

extension CapsicumMisskeyNotificationExtension on MisskeyNotification {
  Notification toCapsicum(
    String localHost, {
    Set<String> adminRoleIds = const {},
  }) {
    return Notification(
      id: id,
      type: misskeyNotificationTypeMap[type] ?? NotificationType.other,
      createdAt: createdAt,
      user: user?.toCapsicum(localHost, adminRoleIds: adminRoleIds),
      post: note?.toCapsicum(localHost, adminRoleIds: adminRoleIds),
    );
  }
}

extension CapsicumMisskeyAnnouncementExtension on MisskeyAnnouncement {
  Announcement toCapsicum() {
    return Announcement(
      id: id,
      content: text,
      title: title,
      imageUrl: imageUrl,
      publishedAt: createdAt,
      read: isRead,
      isHtml: false,
    );
  }
}

extension CapsicumMisskeyListExtension on MisskeyList {
  PostList toCapsicum() {
    return PostList(id: id, title: name);
  }
}

extension CapsicumMisskeyDriveFileExtension on MisskeyDriveFile {
  Attachment toCapsicum() {
    return Attachment(
      id: id,
      type: _mapMisskeyFileType(type),
      url: url ?? '',
      previewUrl: thumbnailUrl,
      description: comment,
    );
  }
}

Poll? _parseMisskeyPoll(Map<String, dynamic>? poll, String noteId) {
  if (poll == null) return null;
  final choices = poll['choices'] as List<dynamic>?;
  if (choices == null) return null;
  final expiresAtStr = poll['expiresAt'] as String?;
  final expired =
      expiresAtStr != null &&
      DateTime.tryParse(expiresAtStr)?.isBefore(DateTime.now()) == true;
  return Poll(
    id: noteId,
    options: choices
        .map(
          (c) => PollOption(
            title: (c as Map<String, dynamic>)['text'] as String? ?? '',
            votesCount: c['votes'] as int? ?? 0,
          ),
        )
        .toList(),
    votersCount: choices.fold<int>(
      0,
      (sum, c) => sum + ((c as Map<String, dynamic>)['votes'] as int? ?? 0),
    ),
    multiple: poll['multiple'] as bool? ?? false,
    expired: expired,
    expiresAt: expiresAtStr != null ? DateTime.tryParse(expiresAtStr) : null,
    voted: choices.any(
      (c) => (c as Map<String, dynamic>)['isVoted'] as bool? ?? false,
    ),
    ownVotes: [
      for (var i = 0; i < choices.length; i++)
        if ((choices[i] as Map<String, dynamic>)['isVoted'] as bool? ?? false)
          i,
    ],
  );
}

AttachmentType _mapMisskeyFileType(String mimeType) {
  if (mimeType.startsWith('image/')) return AttachmentType.image;
  if (mimeType.startsWith('video/')) return AttachmentType.video;
  if (mimeType.startsWith('audio/')) return AttachmentType.audio;
  return AttachmentType.unknown;
}

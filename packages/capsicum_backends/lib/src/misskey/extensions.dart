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
  User toCapsicum(String localHost) {
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
      fields: (fields ?? [])
          .map(
            (f) => UserField(
              name: f['name'] as String? ?? '',
              value: f['value'] as String? ?? '',
            ),
          )
          .toList(),
      emojis: emojis ?? const {},
    );
  }
}

extension CapsicumMisskeyNoteExtension on MisskeyNote {
  Post toCapsicum(String localHost) {
    // Misskey: renote + text = quote, renote without text = simple renote
    final isQuote = renote != null && text != null;
    return Post(
      id: id,
      postedAt: createdAt,
      author: user.toCapsicum(localHost),
      content: text,
      scope: misskeyVisibilityRosetta[visibility] ?? PostScope.public,
      attachments: (files ?? []).map((f) => f.toCapsicum()).toList(),
      sensitive: (files ?? []).any((f) => f.isSensitive),
      reblogCount: renoteCount,
      replyCount: repliesCount,
      reactions: reactions ?? const {},
      myReaction: myReaction,
      reactionEmojis: reactionEmojis ?? const {},
      reblog: isQuote ? null : renote?.toCapsicum(localHost),
      quote: isQuote ? renote?.toCapsicum(localHost) : null,
      poll: _parseMisskeyPoll(poll, id),
      spoilerText: cw,
      emojis: reactionEmojis ?? const {},
      emojiHost: localHost,
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
  Notification toCapsicum(String localHost) {
    return Notification(
      id: id,
      type: misskeyNotificationTypeMap[type] ?? NotificationType.other,
      createdAt: createdAt,
      user: user?.toCapsicum(localHost),
      post: note?.toCapsicum(localHost),
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

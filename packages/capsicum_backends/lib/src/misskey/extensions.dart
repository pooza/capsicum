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
    );
  }
}

extension CapsicumMisskeyNoteExtension on MisskeyNote {
  Post toCapsicum(String localHost) {
    return Post(
      id: id,
      postedAt: createdAt,
      author: user.toCapsicum(localHost),
      content: text,
      scope: misskeyVisibilityRosetta[visibility] ?? PostScope.public,
      attachments: (files ?? []).map((f) => f.toCapsicum()).toList(),
      reblogCount: renoteCount,
      replyCount: repliesCount,
      reactions: reactions ?? const {},
      myReaction: myReaction,
      reactionEmojis: reactionEmojis ?? const {},
      reblog: renote?.toCapsicum(localHost),
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

AttachmentType _mapMisskeyFileType(String mimeType) {
  if (mimeType.startsWith('image/')) return AttachmentType.image;
  if (mimeType.startsWith('video/')) return AttachmentType.video;
  if (mimeType.startsWith('audio/')) return AttachmentType.audio;
  return AttachmentType.unknown;
}

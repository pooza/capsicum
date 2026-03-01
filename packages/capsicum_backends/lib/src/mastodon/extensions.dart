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
    );
  }
}

extension CapsicumMastodonStatusExtension on MastodonStatus {
  Post toCapsicum(String localHost) {
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
      inReplyToId: inReplyToId,
      reblog: reblog?.toCapsicum(localHost),
    );
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

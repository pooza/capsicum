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
      isCat: isCat ?? false,
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
      canChat: canChat,
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
      isHtml: false,
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
  'login': NotificationType.login,
  'createToken': NotificationType.createToken,
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
      reaction: reaction,
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
      name: name,
    );
  }
}

/// Misskey の chat メッセージレスポンス Map → ChatMessage 変換。
///
/// `/api/chat/messages/user-timeline` 等は `fromUser` / `toUser` のオブジェクトを
/// 省略し `fromUserId` / `toUserId` だけ返すことがある（呼び出し元の文脈で
/// 自明だから）。そのフォールバックとして [selfUser] / [counterpartyUser] を
/// 受け取り、ID 一致するものを差し込む。
///
/// [defaultIsRead] は `isRead` フィールドが入って来ないレスポンス
/// (`ChatMessageLiteFor1on1`: user-timeline / create-to-user / streaming
/// newChatMessage) に対するデフォルト値 (#447)。user-timeline は呼び出し
/// 時点で既読更新されるため呼び出し側で `defaultIsRead: true` を渡す。
ChatMessage misskeyChatMessageFromMap(
  Map<String, dynamic> data,
  String localHost, {
  Set<String> adminRoleIds = const {},
  User? selfUser,
  User? counterpartyUser,
  bool defaultIsRead = false,
}) {
  User resolveUser(String userIdKey, String userObjKey) {
    final embedded = data[userObjKey] as Map<String, dynamic>?;
    if (embedded != null) {
      return MisskeyUser.fromJson(
        embedded,
      ).toCapsicum(localHost, adminRoleIds: adminRoleIds);
    }
    final id = data[userIdKey] as String;
    if (selfUser != null && selfUser.id == id) return selfUser;
    if (counterpartyUser != null && counterpartyUser.id == id) {
      return counterpartyUser;
    }
    return User(id: id, username: '?');
  }

  User? resolveOptionalUser(String userIdKey, String userObjKey) {
    final embedded = data[userObjKey] as Map<String, dynamic>?;
    final id = data[userIdKey] as String?;
    if (embedded == null && id == null) return null;
    return resolveUser(userIdKey, userObjKey);
  }

  final fileMap = data['file'] as Map<String, dynamic>?;
  final rawEmojis = data['emojis'];
  final emojis = rawEmojis is Map
      ? Map<String, String>.fromEntries(
          rawEmojis.entries
              .where((e) => e.value is String)
              .map((e) => MapEntry(e.key as String, e.value as String)),
        )
      : const <String, String>{};
  final toRoomId = data['toRoomId'] as String?;
  final toRoomMap = data['toRoom'] as Map<String, dynamic>?;
  return ChatMessage(
    id: data['id'] as String,
    createdAt: DateTime.parse(data['createdAt'] as String),
    fromUser: resolveUser('fromUserId', 'fromUser'),
    toUser: resolveOptionalUser('toUserId', 'toUser'),
    toRoom: toRoomMap != null
        ? misskeyChatRoomFromMap(
            toRoomMap,
            localHost,
            adminRoleIds: adminRoleIds,
          )
        : null,
    toRoomId: toRoomId,
    text: data['text'] as String?,
    file: fileMap != null
        ? MisskeyDriveFile.fromJson(fileMap).toCapsicum()
        : null,
    isRead: data['isRead'] as bool? ?? defaultIsRead,
    emojis: emojis,
  );
}

ChatThread misskeyChatThreadFromHistoryEntry(
  Map<String, dynamic> entry,
  String localHost,
  String myUserId, {
  Set<String> adminRoleIds = const {},
}) {
  final lastMessage = misskeyChatMessageFromMap(
    entry,
    localHost,
    adminRoleIds: adminRoleIds,
  );
  if (lastMessage.isRoomMessage) {
    // chat/history?room=true から来るルームスレッド。toRoom は packMessageDetailed
    // 側で populate されている前提だが、極稀に欠落しても roomId だけで仮設の
    // ChatRoom を作って表示は維持する。
    final room =
        lastMessage.toRoom ??
        ChatRoom(
          id: lastMessage.toRoomId!,
          createdAt: lastMessage.createdAt,
          name: '?',
          description: '',
          ownerId: '',
          owner: User(id: '', username: '?'),
        );
    final isIncoming = lastMessage.fromUser.id != myUserId;
    return ChatThread(
      room: room,
      lastMessage: lastMessage,
      isUnread: isIncoming && !lastMessage.isRead,
    );
  }
  final isIncoming = lastMessage.fromUser.id != myUserId;
  return ChatThread(
    otherUser: isIncoming ? lastMessage.fromUser : lastMessage.toUser,
    lastMessage: lastMessage,
    isUnread: isIncoming && !lastMessage.isRead,
  );
}

/// Misskey の `ChatRoom` レスポンスを capsicum 型に変換する。
ChatRoom misskeyChatRoomFromMap(
  Map<String, dynamic> data,
  String localHost, {
  Set<String> adminRoleIds = const {},
}) {
  final ownerMap = data['owner'] as Map<String, dynamic>?;
  final ownerId =
      data['ownerId'] as String? ?? ownerMap?['id'] as String? ?? '';
  final owner = ownerMap != null
      ? MisskeyUser.fromJson(
          ownerMap,
        ).toCapsicum(localHost, adminRoleIds: adminRoleIds)
      : User(id: ownerId, username: '?');
  return ChatRoom(
    id: data['id'] as String,
    createdAt: DateTime.parse(data['createdAt'] as String),
    name: data['name'] as String? ?? '',
    description: data['description'] as String? ?? '',
    ownerId: ownerId,
    owner: owner,
    isMuted: data['isMuted'] as bool? ?? false,
    invitationExists: data['invitationExists'] as bool? ?? false,
  );
}

/// `ChatRoomMembership` レスポンス → capsicum [ChatRoomMember]。
ChatRoomMember misskeyChatRoomMemberFromMap(
  Map<String, dynamic> data,
  String localHost, {
  Set<String> adminRoleIds = const {},
}) {
  final roomMap = data['room'] as Map<String, dynamic>?;
  final userMap = data['user'] as Map<String, dynamic>?;
  return ChatRoomMember(
    id: data['id'] as String,
    createdAt: DateTime.parse(data['createdAt'] as String),
    roomId: data['roomId'] as String,
    userId: data['userId'] as String,
    isMuted: data['isMuted'] as bool? ?? false,
    room: roomMap != null
        ? misskeyChatRoomFromMap(roomMap, localHost, adminRoleIds: adminRoleIds)
        : null,
    user: userMap != null
        ? MisskeyUser.fromJson(
            userMap,
          ).toCapsicum(localHost, adminRoleIds: adminRoleIds)
        : null,
  );
}

/// `ChatRoomInvitation` レスポンス → capsicum [ChatRoomInvitation]。
ChatRoomInvitation misskeyChatRoomInvitationFromMap(
  Map<String, dynamic> data,
  String localHost, {
  Set<String> adminRoleIds = const {},
}) {
  final roomMap = data['room'] as Map<String, dynamic>?;
  final userMap = data['user'] as Map<String, dynamic>?;
  return ChatRoomInvitation(
    id: data['id'] as String,
    createdAt: DateTime.parse(data['createdAt'] as String),
    roomId: data['roomId'] as String,
    userId: data['userId'] as String,
    room: roomMap != null
        ? misskeyChatRoomFromMap(roomMap, localHost, adminRoleIds: adminRoleIds)
        : null,
    user: userMap != null
        ? MisskeyUser.fromJson(
            userMap,
          ).toCapsicum(localHost, adminRoleIds: adminRoleIds)
        : null,
  );
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

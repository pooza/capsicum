import 'attachment.dart';
import 'chat_room.dart';
import 'user.dart';

class ChatMessage {
  final String id;
  final DateTime createdAt;
  final User fromUser;

  /// DM 宛先ユーザー。ルーム宛メッセージ (`toRoom` が非 null) のときは null。
  final User? toUser;

  /// ルーム宛メッセージの宛先ルーム。DM (`toUser` が非 null) のときは null。
  /// Misskey の `ChatMessageLiteForRoom` は `toRoomId` のみで packedRoom を返さず、
  /// クライアント側で `chat/rooms/show` 等から補完する想定。本フィールドは
  /// 補完されている場合のみ非 null。
  final ChatRoom? toRoom;

  /// ルーム宛メッセージで `toRoom` が補完されていない場合の生の roomId。
  /// DM のときは null。
  final String? toRoomId;

  final String? text;
  final Attachment? file;
  final bool isRead;

  /// メッセージ本文中の MFM shortcode → 画像 URL マップ。Misskey の
  /// `/api/chat/messages/*` レスポンスの `emojis` フィールド由来。
  /// 通常投稿の `Post.emojis` と同型 (#449)。
  final Map<String, String> emojis;

  const ChatMessage({
    required this.id,
    required this.createdAt,
    required this.fromUser,
    this.toUser,
    this.toRoom,
    this.toRoomId,
    this.text,
    this.file,
    this.isRead = false,
    this.emojis = const {},
  });

  /// ルーム宛メッセージか (DM か) の判定。
  bool get isRoomMessage => toRoomId != null || toRoom != null;
}

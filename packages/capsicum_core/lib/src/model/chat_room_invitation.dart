import 'chat_room.dart';
import 'user.dart';

/// ルーム招待 (`/api/chat/rooms/invitations/{inbox,outbox}` のレスポンス
/// `ChatRoomInvitation` に対応)。
///
/// - inbox (受信): `room` が populate、`user` は誘った側
/// - outbox (送信): `user` が populate (誘われた側)、`room` は自分のルーム
class ChatRoomInvitation {
  final String id;
  final DateTime createdAt;
  final String roomId;
  final String userId;
  final ChatRoom? room;
  final User? user;

  const ChatRoomInvitation({
    required this.id,
    required this.createdAt,
    required this.roomId,
    required this.userId,
    this.room,
    this.user,
  });
}

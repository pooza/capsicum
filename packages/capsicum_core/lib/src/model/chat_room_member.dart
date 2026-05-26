import 'chat_room.dart';
import 'user.dart';

/// ルームメンバーシップ (`/api/chat/rooms/members` / `/api/chat/rooms/joining`
/// のレスポンス `ChatRoomMembership` に対応)。`room` か `user` のどちらが
/// populate されるかは呼び出した API による:
///
/// - `/joining` (自分の参加ルーム一覧): `room` が populate、`user` は null
/// - `/members` (特定ルームのメンバー一覧): `user` が populate、`room` は null
class ChatRoomMember {
  final String id;
  final DateTime createdAt;
  final String roomId;
  final String userId;
  final bool isMuted;
  final ChatRoom? room;
  final User? user;

  const ChatRoomMember({
    required this.id,
    required this.createdAt,
    required this.roomId,
    required this.userId,
    this.isMuted = false,
    this.room,
    this.user,
  });
}

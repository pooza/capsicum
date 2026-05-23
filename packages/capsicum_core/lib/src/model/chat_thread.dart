import 'chat_message.dart';
import 'chat_room.dart';
import 'user.dart';

/// chat 履歴画面のスレッド 1 行。DM (1 対 1) とルーム (グループチャット) を
/// 同一画面に出すため、`otherUser` か `room` のどちらか一方が非 null になる
/// (排他)。判定は [isRoom] / [isDm] で行う。
class ChatThread {
  /// DM 相手。ルームスレッドのときは null。
  final User? otherUser;

  /// ルーム本体。DM スレッドのときは null。
  final ChatRoom? room;

  final ChatMessage lastMessage;
  final bool isUnread;

  const ChatThread({
    this.otherUser,
    this.room,
    required this.lastMessage,
    this.isUnread = false,
  }) : assert(
         (otherUser != null) != (room != null),
         'ChatThread は otherUser か room のどちらか一方のみを持つ',
       );

  bool get isRoom => room != null;
  bool get isDm => otherUser != null;
}

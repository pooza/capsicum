import 'chat_message.dart';
import 'user.dart';

class ChatThread {
  final User otherUser;
  final ChatMessage lastMessage;
  final bool isUnread;

  const ChatThread({
    required this.otherUser,
    required this.lastMessage,
    this.isUnread = false,
  });
}

import 'attachment.dart';
import 'user.dart';

class ChatMessage {
  final String id;
  final DateTime createdAt;
  final User fromUser;
  final User toUser;
  final String? text;
  final Attachment? file;
  final bool isRead;

  const ChatMessage({
    required this.id,
    required this.createdAt,
    required this.fromUser,
    required this.toUser,
    this.text,
    this.file,
    this.isRead = false,
  });
}

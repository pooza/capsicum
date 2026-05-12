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

  /// メッセージ本文中の MFM shortcode → 画像 URL マップ。Misskey の
  /// `/api/chat/messages/*` レスポンスの `emojis` フィールド由来。
  /// 通常投稿の `Post.emojis` と同型 (#449)。
  final Map<String, String> emojis;

  const ChatMessage({
    required this.id,
    required this.createdAt,
    required this.fromUser,
    required this.toUser,
    this.text,
    this.file,
    this.isRead = false,
    this.emojis = const {},
  });
}

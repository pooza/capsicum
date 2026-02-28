import 'post.dart';
import 'user.dart';

enum NotificationType {
  mention,
  reblog,
  favourite,
  follow,
  followRequest,
  reaction,
  poll,
  update,
  other,
}

class Notification {
  final String id;
  final NotificationType type;
  final DateTime createdAt;
  final User? user;
  final Post? post;
  final bool unread;

  const Notification({
    required this.id,
    required this.type,
    required this.createdAt,
    this.user,
    this.post,
    this.unread = true,
  });
}

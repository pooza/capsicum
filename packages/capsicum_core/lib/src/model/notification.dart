import 'announcement.dart';
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
  login,
  createToken,
  chat,
  announcement,
  other,
}

class Notification {
  final String id;
  final NotificationType type;
  final DateTime createdAt;
  final User? user;
  final Post? post;
  final String? reaction;
  final bool unread;

  /// `type == NotificationType.announcement` のときのお知らせ本体 (#569)。
  /// お知らせは [user] / [post] を持たず本文を [Announcement.content] に
  /// 抱えるため、デスクトップ通知ディスパッチャ等が本文を取り出せるよう
  /// 別途保持する。それ以外の type では null。
  final Announcement? announcement;

  const Notification({
    required this.id,
    required this.type,
    required this.createdAt,
    this.user,
    this.post,
    this.reaction,
    this.unread = true,
    this.announcement,
  });
}

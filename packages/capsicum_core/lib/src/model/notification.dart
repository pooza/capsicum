import 'announcement.dart';
import 'collection.dart';
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
  // Mastodon 4.6 Collections (FEP-7aa9) の被フィーチャー通知 (#741)。Misskey 等価なし。
  addedToCollection,
  collectionUpdate,
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

  /// `type == addedToCollection / collectionUpdate` のとき同梱される対象
  /// コレクション (#741)。どのコレクションに載せられた／更新されたかを通知行に
  /// 表示するために保持する。それ以外の type では null。
  final Collection? collection;

  const Notification({
    required this.id,
    required this.type,
    required this.createdAt,
    this.user,
    this.post,
    this.reaction,
    this.unread = true,
    this.announcement,
    this.collection,
  });
}

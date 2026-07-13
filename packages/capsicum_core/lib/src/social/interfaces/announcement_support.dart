import '../../model/announcement.dart';

abstract mixin class AnnouncementSupport {
  Future<List<Announcement>> getAnnouncements();
  Future<void> dismissAnnouncement(String id);
}

/// お知らせへのリアクション対応 (#819)。Mastodon のみが提供する（Misskey の
/// お知らせは絵文字リアクションを持たない）ため、[AnnouncementSupport] とは別の
/// mixin にして `adapter is AnnouncementReactionSupport` で出し分ける。
abstract mixin class AnnouncementReactionSupport {
  /// お知らせにリアクションを付ける。[name] は Unicode 絵文字またはカスタム
  /// 絵文字の shortcode（コロン無し）。
  Future<void> addAnnouncementReaction(String id, String name);

  /// お知らせのリアクションを外す。
  Future<void> removeAnnouncementReaction(String id, String name);
}

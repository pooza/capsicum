class Announcement {
  final String id;
  final String content;
  final String? title;
  final String? imageUrl;
  final DateTime publishedAt;
  final bool read;
  final bool isHtml;
  final List<AnnouncementReaction> reactions;

  const Announcement({
    required this.id,
    required this.content,
    this.title,
    this.imageUrl,
    required this.publishedAt,
    this.read = false,
    this.isHtml = false,
    this.reactions = const [],
  });

  Announcement copyWith({bool? read, List<AnnouncementReaction>? reactions}) =>
      Announcement(
        id: id,
        content: content,
        title: title,
        imageUrl: imageUrl,
        publishedAt: publishedAt,
        read: read ?? this.read,
        isHtml: isHtml,
        reactions: reactions ?? this.reactions,
      );
}

/// お知らせに付いたリアクション 1 種 (#819)。[name] は Unicode 絵文字または
/// カスタム絵文字の shortcode（コロン無し）。カスタム絵文字のときのみ [url] が
/// 付き、チップ描画で画像として使う。
class AnnouncementReaction {
  final String name;
  final int count;

  /// 自分がこのリアクションを付けているか。
  final bool me;
  final String? url;

  const AnnouncementReaction({
    required this.name,
    required this.count,
    this.me = false,
    this.url,
  });

  AnnouncementReaction copyWith({int? count, bool? me}) => AnnouncementReaction(
    name: name,
    count: count ?? this.count,
    me: me ?? this.me,
    url: url,
  );
}

/// お知らせを通知の 1 行にしたときの id の前置き（`announcement:<id>`）。
///
/// ⚠⚠ **サーバーの通知の id と見分けるための印**（#1308）。既読位置や続き読みの
/// カーソルからお知らせの行を外すのにこれを見るので、ストリーミングの経路と
/// 一覧に差し込む経路で同じものを使う（片方だけ変えると、お知らせの id を
/// サーバーの通知の id として送ってしまう）。
const announcementNotificationIdPrefix = 'announcement:';

class Announcement {
  final String id;
  final String content;
  final String? title;
  final String? imageUrl;
  final DateTime publishedAt;

  /// 最後に編集された時刻。無ければ null (#1308)。
  ///
  /// ⚠ **Mastodon は編集していなくても値を返す**（作成時の時刻）。編集されたか
  /// どうかは [edited] で見る。
  final DateTime? updatedAt;
  final bool read;
  final bool isHtml;
  final List<AnnouncementReaction> reactions;

  /// サーバーがこのお知らせへのリアクションを受け付けるか (#1321)。
  /// Mastodon 5.0 で無効にできるようになった。無効のときに付け外しすると 400 になる。
  final bool reactionsAllowed;

  /// 掲載期間 (#1214)。Mastodon だけが持ち、指定が無ければ null。
  final DateTime? startsAt;
  final DateTime? endsAt;

  /// 終日のお知らせか。真なら時刻を出さない。
  final bool allDay;

  const Announcement({
    required this.id,
    required this.content,
    this.title,
    this.imageUrl,
    required this.publishedAt,
    this.updatedAt,
    this.read = false,
    this.isHtml = false,
    this.reactions = const [],
    this.reactionsAllowed = true,
    this.startsAt,
    this.endsAt,
    this.allDay = false,
  });

  /// 公開したあとに編集されたか (#1308)。
  ///
  /// ⚠ 1 分までの差は編集と見なさない。Mastodon は作成時にも `updated_at` を
  /// 入れ、予約して公開したお知らせでは `published_at` と数秒ずれる。
  bool get edited {
    final updated = updatedAt;
    if (updated == null) return false;
    return updated.difference(publishedAt) > const Duration(minutes: 1);
  }

  Announcement copyWith({bool? read, List<AnnouncementReaction>? reactions}) =>
      Announcement(
        id: id,
        content: content,
        title: title,
        imageUrl: imageUrl,
        publishedAt: publishedAt,
        updatedAt: updatedAt,
        read: read ?? this.read,
        isHtml: isHtml,
        reactions: reactions ?? this.reactions,
        reactionsAllowed: reactionsAllowed,
        startsAt: startsAt,
        endsAt: endsAt,
        allDay: allDay,
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

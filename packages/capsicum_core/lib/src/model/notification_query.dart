import 'notification.dart';

/// 通知の取得条件のうち、ページングではない部分 (#1042 / #1048)。
///
/// ⚠ **ページングは [TimelineQuery] のまま。**こちらは「何を出すか」だけを持つ。
/// 2 つに分けてあるのは、**バックグラウンド取得や未読数の計算が絞り込みを
/// 引き継いではいけない**から（#1042 の「サーバー側で絞ると未読の総数の意味が
/// 変わる」）。`filter` を渡さない呼び出しは従来どおり全種別・非グループで取る。
class NotificationQuery {
  /// 出さない種別。空なら全種別。
  ///
  /// ⚠⚠ **「出す種別」ではなく「出さない種別」を持つ。**サーバーへは
  /// `exclude_types[]` / `excludeTypes` として渡る。許可リスト
  /// （`types[]`）にすると、**capsicum が名前を知らない種別が黙って消える** —
  /// 上流で種別が増えたときに「絞り込み中だけ新しい通知が来ない」という、
  /// 原因の見えない形で出る。拒否リストなら、取りこぼしは「消し忘れた種別が
  /// 見えている」という**気付ける方向**に倒れる。
  ///
  /// ⚠ [NotificationType.other] は指定しても効かない（サーバー側の名前を
  /// 列挙できないため）。UI の候補にも出さないこと。
  final Set<NotificationType> excludeTypes;

  /// 同じ投稿への反応を束ねて受け取るか (#1048)。
  ///
  /// ⚠ **true でもサーバーが束ねられる種別しか束ならない。**Mastodon は
  /// `favourite` / `reblog` / `follow`、Misskey は `reaction` / `renote` だけ。
  /// それ以外は 1 件 1 グループで返る。
  final bool grouped;

  const NotificationQuery({this.excludeTypes = const {}, this.grouped = false});

  bool get isFiltered => excludeTypes.isNotEmpty;
}

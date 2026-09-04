import '../../model/timeline_query.dart';
import '../../model/user.dart';

/// 自分宛のフォローリクエストを処理する (#1040)。
///
/// ⚠ **通知の型はあるのに操作が無かった。**`NotificationType.followRequest` は
/// モデルにも表示にもあるので「フォローリクエストが来ました」は通知画面に出る
/// が、そこから先が無く、**鍵アカウント（`locked`）のユーザーは capsicum だけ
/// では承認も拒否もできない**状態だった。処理するには WebUI を開くしかない。
///
/// ## 範囲は受け側だけ
///
/// ⚠ **送り側（自分が出した申請の一覧・取り消し）は入れていない**
/// （2026-09-04 pooza 判断）。Misskey は `following/requests/sent` /
/// `cancel` を持つが、**Mastodon に等価物が無い**ので、入れると片方だけの
/// 機能になる。動機も違う（受け側は鍵アカウント運用者の日常の困りごと、
/// 送り側は頻度の低い操作）。
///
/// ⚠ **後で非対称が残ることは承知の上。**送り側が要るとなったら、そのときに
/// Mastodon 側の代替（`relationships` の `requested` を見る等）ごと設計する。
abstract mixin class FollowRequestSupport {
  /// 自分宛の未処理フォローリクエスト一覧。
  Future<({List<User> users, String? nextCursor})> getFollowRequests({
    TimelineQuery? query,
  });

  /// [userId] からの申請を承認する。
  ///
  /// ⚠ **渡すのは申請者の User id。**Mastodon の
  /// `POST /api/v1/follow_requests/:id/authorize` の `:id` は account id で、
  /// 申請レコードの id ではない。
  Future<void> authorizeFollowRequest(String userId);

  /// [userId] からの申請を拒否する。
  Future<void> rejectFollowRequest(String userId);
}

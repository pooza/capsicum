/// 特定の相手のブースト / リノートだけを TL に出さない (#1245)。
///
/// ⚠ **人のミュートとは別物。**相手自身の投稿は今までどおり出る。
///
/// 絞るのはサーバーで、ストリーミングで届くぶんも落ちる（Mastodon は配送時の
/// `FeedManager`、Misskey は接続ごとのミュート判定）。端末側で TL を絞る処理は
/// 要らない。いまの状態は `UserRelationship.showingReposts` で読む。
abstract mixin class RepostMuteSupport {
  /// フォロー中の相手にしか設定できないか。
  ///
  /// Mastodon はフォローの属性（`reblogs`）なので true。Misskey はフォローと
  /// 独立した設定（`renote-mute/*`）なので false。
  bool get repostMuteRequiresFollow;

  /// [userId] のブースト / リノートを出す（[show] が true）か、出さないか。
  Future<void> setShowReposts(String userId, {required bool show});
}

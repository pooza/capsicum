/// フォロー中の相手ごとに、その人の返信を TL に流すかを決める (#1211)。
///
/// Misskey のフォローの属性（`withReplies`）。Mastodon のリストの
/// `replies_policy` と同じ「返信をどこまで流すか」の族だが、こちらはフォロー
/// 関係 1 つずつに付く。
///
/// 絞るのはサーバーで、端末側で TL を絞る処理は要らない。いまの状態は
/// `UserRelationship.showingReplies` で読む（null なら切り替えられない）。
abstract mixin class FollowRepliesSupport {
  /// [userId] の返信を TL に流す（[show] が true）か、流さないか。
  ///
  /// ⚠ フォロー中の相手にしか使えない。
  Future<void> setShowReplies(String userId, {required bool show});
}

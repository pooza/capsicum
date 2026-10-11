import '../../model/post.dart';

/// 会話（スレッド）のミュート (#1208)。その会話から自分へ届く通知だけを止める。
///
/// ⚠ **人のミュートでも、キーワードミュートでもない。**人のミュートは相手の
/// 投稿が TL から消えるので、荒れたスレッドを降りたいだけのときには重い。
///
/// [postId] は**会話のどの投稿でもよい**（ルートに限らない）。Mastodon は
/// 投稿の `conversation`、Misskey は `threadId ?? id` で引く。
abstract mixin class ThreadMuteSupport {
  /// 会話をミュートする。既にミュート中でも成功として返す。
  Future<Post> muteThread(String postId);

  Future<Post> unmuteThread(String postId);

  /// いまミュート中か。
  ///
  /// ⚠ [Post.threadMuted] が null（投稿に状態が載らない・Misskey）のときに引く。
  /// 載っているなら（Mastodon）そちらを見れば足り、ここは呼ばなくてよい。
  Future<bool> isThreadMuted(String postId);
}

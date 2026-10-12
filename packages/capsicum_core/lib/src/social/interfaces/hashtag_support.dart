import '../../model/hashtag_spec.dart';
import '../../model/post.dart';
import '../../model/timeline_query.dart';

abstract mixin class HashtagSupport {
  Future<bool> isFollowingHashtag(String hashtag);
  Future<void> followHashtag(String hashtag);
  Future<void> unfollowHashtag(String hashtag);

  /// [condition] に合う投稿を返す (#1209)。
  ///
  /// ⚠⚠ **除外（[HashtagQuery.none]）は、サーバーが受けられる SNS だけが絞る。**
  /// Mastodon は `none[]` で絞るが、Misskey には受け口が無いので絞らずに返る。
  /// **呼び出し側が [HashtagQuery.excludes] で落とす**（ストリーミングで届くぶんも
  /// 同じ場所で落とせるので、アダプタの中で絞らない）。
  Future<List<Post>> getPostsByHashtag(
    HashtagQuery condition, {
    TimelineQuery? query,
  });

  /// フォロー中のハッシュタグ一覧 (#1070)。返すのは `#` を含まないタグ名。
  ///
  /// ⚠⚠ **これが無いと解除の導線が「そのタグのタイムラインを開く」経路にしか
  /// 無い。**何をフォローしたか忘れると解除する手段が事実上なくなる。#1039
  /// （ミュートすると相手が TL から消えるので解除できない）と同じ構造。
  ///
  /// ⚠ **Mastodon 固有。**Misskey にはハッシュタグのフォローという概念が無い
  /// ので、そちらは常に空を返す。
  Future<({List<String> tags, String? nextCursor})> getFollowedHashtags({
    TimelineQuery? query,
  });
}

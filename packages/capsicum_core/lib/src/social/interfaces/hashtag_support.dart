import '../../model/post.dart';
import '../../model/timeline_query.dart';

abstract mixin class HashtagSupport {
  Future<bool> isFollowingHashtag(String hashtag);
  Future<void> followHashtag(String hashtag);
  Future<void> unfollowHashtag(String hashtag);
  Future<List<Post>> getPostsByHashtag(
    String hashtag, {
    TimelineQuery? query,
    List<String>? all,
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

import '../../model/channel.dart';
import '../../model/post.dart';
import '../../model/timeline_query.dart';

abstract mixin class ChannelSupport {
  Future<List<Channel>> getFollowedChannels();
  Future<List<Post>> getChannelTimeline(
    String channelId, {
    TimelineQuery? query,
  });

  /// 投稿を指定チャンネル**内へ**リノートする (#895)。
  ///
  /// 通常のリノート（[BackendAdapter.repeatPost]）はチャンネル外に出るため、
  /// チャンネルへ流したい場合はこちらを使う。チャンネル投稿の公開範囲は
  /// チャンネル自身が決めるので visibility は取らない。
  Future<Post> repeatPostToChannel(String postId, {required String channelId});
}

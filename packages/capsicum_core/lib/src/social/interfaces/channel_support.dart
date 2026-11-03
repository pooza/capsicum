import '../../model/channel.dart';
import '../../model/post.dart';
import '../../model/timeline_query.dart';

abstract mixin class ChannelSupport {
  Future<List<Channel>> getFollowedChannels();

  /// チャンネルを 1 件取る (#1296)。
  ///
  /// フォローしていないチャンネル（投稿から開いたデッキのカラム等）は
  /// [getFollowedChannels] に無いので、名前を引き直すときはこちらを使う。
  Future<Channel> getChannel(String channelId);
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

/// チャンネルを探す・購読する・作る (#1051)。
abstract mixin class ChannelManagementSupport {
  Future<List<Channel>> searchChannels(String query);
  Future<List<Channel>> getFeaturedChannels();
  Future<List<Channel>> getFavoriteChannels();
  Future<List<Channel>> getOwnedChannels();
  Future<void> followChannel(String channelId);
  Future<void> unfollowChannel(String channelId);
  Future<void> favoriteChannel(String channelId);
  Future<void> unfavoriteChannel(String channelId);
  Future<void> muteChannel(String channelId);
  Future<void> unmuteChannel(String channelId);
  Future<void> createChannel(ChannelDraft draft);
  Future<void> updateChannel(String channelId, ChannelDraft draft);
}

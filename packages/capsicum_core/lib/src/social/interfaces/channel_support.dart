import '../../model/channel.dart';
import '../../model/post.dart';
import '../../model/timeline_query.dart';

abstract mixin class ChannelSupport {
  Future<List<Channel>> getFollowedChannels();
  Future<List<Post>> getChannelTimeline(
    String channelId, {
    TimelineQuery? query,
  });
}

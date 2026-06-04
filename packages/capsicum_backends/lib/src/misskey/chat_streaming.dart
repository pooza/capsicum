import 'package:capsicum_core/capsicum_core.dart';

import 'chat_streaming_base.dart';
import 'extensions.dart';

/// Misskey の `main` channel を購読し、`newChatMessage` イベントを
/// `ChatMessage` ストリームとして配信する。
///
/// `main` channel は notification / mention / newChatMessage 等多数のイベントを
/// 流すが、本クラスは chat 用に `newChatMessage` のみフィルタして emit する。
/// より granular なスレッド単位イベント (read / deleted / reaction) が必要なら
/// 別途 `chatUser` channel (otherId 必須) を購読する。
///
/// 再接続機構・観測コールバック等の共通部分は [MisskeyChatStreamingBase] に
/// 集約している (#627)。
class MisskeyChatStreaming extends MisskeyChatStreamingBase {
  MisskeyChatStreaming({
    required super.host,
    required super.accessToken,
    super.adminRoleIds,
    super.selfUser,
    super.onParseError,
    super.onStreamError,
    super.onReconnectExhausted,
  });

  @override
  Map<String, dynamic> buildConnectBody(String subscriptionId) => {
    'channel': 'main',
    'id': subscriptionId,
  };

  @override
  ChatMessage? parseChannelMessage(Map<String, dynamic> body) {
    if (body['type'] != 'newChatMessage') return null;
    final messageBody = body['body'];
    if (messageBody is! Map<String, dynamic>) return null;
    return misskeyChatMessageFromMap(
      messageBody,
      host,
      adminRoleIds: adminRoleIds,
      selfUser: selfUser,
    );
  }
}

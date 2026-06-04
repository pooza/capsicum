import 'package:capsicum_core/capsicum_core.dart';

import 'chat_streaming_base.dart';
import 'extensions.dart';

/// Misskey の `chatRoom` channel (`{roomId}` param) を購読し、ルーム宛
/// `message` イベントを [ChatMessage] ストリームとして配信する (#438)。
///
/// 1 インスタンス = 1 ルーム。DM 用の [MisskeyChatStreaming] が `main` channel
/// を 1 本だけ張って全 DM を受けるのに対し、ルームはサーバー側仕様 (Misskey の
/// stream/channels/chat-room.ts は `roomId` を init で 1 つだけ受け取る) により
/// 「自分の参加全ルームを 1 本でまとめて受ける aggregate channel」が存在しない。
/// 表示中のルームに対して都度購読 / 切断する運用を前提とする。
///
/// 再接続機構・観測コールバック等の共通部分は [MisskeyChatStreamingBase] に
/// 集約している (#627)。
class MisskeyChatRoomStreaming extends MisskeyChatStreamingBase {
  final String roomId;

  MisskeyChatRoomStreaming({
    required super.host,
    required super.accessToken,
    required this.roomId,
    super.adminRoleIds,
    super.selfUser,
    super.onParseError,
    super.onStreamError,
    super.onReconnectExhausted,
  });

  @override
  Map<String, dynamic> buildConnectBody(String subscriptionId) => {
    'channel': 'chatRoom',
    'id': subscriptionId,
    'params': {'roomId': roomId},
  };

  @override
  ChatMessage? parseChannelMessage(Map<String, dynamic> body) {
    // chatRoom channel が emit するイベント。Misskey は ChatRoomChannel から
    // 「サーバー側 chatRoomStream:<roomId> の全 event type」をそのまま流すため、
    // 新着メッセージは `message` イベントとして来る (read 等の他イベントは
    // 今回スコープ外)。
    if (body['type'] != 'message') return null;
    final messageBody = body['body'];
    if (messageBody is! Map<String, dynamic>) return null;
    // ルーム宛は ChatMessageLiteForRoom 形 (toRoomId のみで toUserId なし)。
    // パーサーは toRoom が無くても toRoomId だけで room メッセージと識別する。
    return misskeyChatMessageFromMap(
      messageBody,
      host,
      adminRoleIds: adminRoleIds,
      selfUser: selfUser,
      defaultIsRead: true,
    );
  }
}

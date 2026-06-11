import 'attachment.dart';
import 'chat_room.dart';
import 'user.dart';

/// chat メッセージへの 1 リアクション (#612)。Misskey の
/// `chat/messages/*` レスポンス `reactions` は `{reaction, user}` の配列で、
/// 通常投稿の `{reaction: count}` 集計マップとは違い「誰が何で反応したか」を
/// 個別に持つ。UI 側で reaction 文字列ごとに集計し、自分の reaction かを
/// `user` で判定する。
class ChatReaction {
  /// `:shortcode:` (カスタム絵文字) または Unicode 絵文字そのもの。
  final String reaction;

  /// この reaction を付けたユーザー。
  final User user;

  const ChatReaction({required this.reaction, required this.user});
}

class ChatMessage {
  final String id;
  final DateTime createdAt;
  final User fromUser;

  /// DM 宛先ユーザー。ルーム宛メッセージ (`toRoom` が非 null) のときは null。
  final User? toUser;

  /// ルーム宛メッセージの宛先ルーム。DM (`toUser` が非 null) のときは null。
  /// Misskey の `ChatMessageLiteForRoom` は `toRoomId` のみで packedRoom を返さず、
  /// クライアント側で `chat/rooms/show` 等から補完する想定。本フィールドは
  /// 補完されている場合のみ非 null。
  final ChatRoom? toRoom;

  /// ルーム宛メッセージで `toRoom` が補完されていない場合の生の roomId。
  /// DM のときは null。
  final String? toRoomId;

  final String? text;
  final Attachment? file;
  final bool isRead;

  /// メッセージ本文中の MFM shortcode → 画像 URL マップ。Misskey の
  /// `/api/chat/messages/*` レスポンスの `emojis` フィールド由来。
  /// 通常投稿の `Post.emojis` と同型 (#449)。
  final Map<String, String> emojis;

  /// メッセージに付いた reaction の一覧 (#612)。各要素は「誰が何で反応したか」
  /// の組。UI 側で reaction 文字列ごとに集計する。
  final List<ChatReaction> reactions;

  const ChatMessage({
    required this.id,
    required this.createdAt,
    required this.fromUser,
    this.toUser,
    this.toRoom,
    this.toRoomId,
    this.text,
    this.file,
    this.isRead = false,
    this.emojis = const {},
    this.reactions = const [],
  });

  /// ルーム宛メッセージか (DM か) の判定。
  bool get isRoomMessage => toRoomId != null || toRoom != null;

  ChatMessage copyWith({List<ChatReaction>? reactions}) => ChatMessage(
    id: id,
    createdAt: createdAt,
    fromUser: fromUser,
    toUser: toUser,
    toRoom: toRoom,
    toRoomId: toRoomId,
    text: text,
    file: file,
    isRead: isRead,
    emojis: emojis,
    reactions: reactions ?? this.reactions,
  );
}

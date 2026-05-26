import '../../model/chat_message.dart';
import '../../model/chat_room.dart';
import '../../model/chat_room_invitation.dart';
import '../../model/chat_room_member.dart';
import '../../model/chat_thread.dart';
import '../../model/timeline_query.dart';

abstract mixin class ChatSupport {
  /// 現アカウントが chat を **読める** か。スレッド一覧表示・ドロワー gate
  /// に使う。サーバー側 chatAvailability の `available` / `readonly` は
  /// どちらも true。
  ///
  /// Misskey の `canChat` フィールドは boolean 1 つで readonly と
  /// unavailable を区別できないため、`canChat=false` が readonly か
  /// unavailable か判定できない。区別が必要になるまでは「読み取りは
  /// permissive に許可してエラーを UI に出す」方針で true 寄りに倒す
  /// (#446)。実装が override しなければ true（互換挙動）。
  bool get canReadChat => true;

  /// 現アカウントが chat を **送信できる** か。新規スレッド作成や送信
  /// ボタンの gate に使う。サーバー側 chatAvailability の `available`
  /// のみ true、`readonly` / `unavailable` は false。
  ///
  /// 実装が override しなければ true（互換挙動）。
  bool get canWriteChat => true;

  /// 後方互換用エイリアス。`canReadChat` と等価 (#446 で 2 段分割)。
  @Deprecated('use canReadChat or canWriteChat instead')
  bool get canUseChat => canReadChat;

  Future<List<ChatThread>> getChatHistory({TimelineQuery? query});
  Future<List<ChatMessage>> getUserMessages({
    required String userId,
    TimelineQuery? query,
  });
  Future<ChatMessage> sendUserMessage({
    required String userId,
    String? text,
    String? fileId,
  });
  Future<void> deleteChatMessage(String messageId);
  Future<void> markAllChatRead();

  /// 新着 chat メッセージを通知する broadcast ストリーム。listen 開始で
  /// WebSocket 接続を立て、onCancel で切断する想定。サーバーの main channel
  /// から `newChatMessage` イベントだけ取り出して emit する。
  ///
  /// [onParseError] は実装内部で raw payload の JSON parse / 型変換に失敗した
  /// ときに呼ばれる任意コールバック。サーバー schema 変更を観測するため、
  /// 呼び出し側 (capsicum 本体) で Sentry breadcrumb / 計装に繋げる用途を
  /// 想定 (#448)。null なら無視。
  ///
  /// [onStreamError] は接続層 (TLS / DNS / WebSocket abort 等) で発生した
  /// error を観測層に流すための任意コールバック。null なら無視 (#552)。
  ///
  /// [onReconnectExhausted] は再接続上限に到達して諦めたときに 1 回だけ
  /// 呼ばれる。UI 警告や Sentry captureMessage に繋ぐ用途を想定 (#552)。
  Stream<ChatMessage> streamChatMessages({
    void Function(Object error, StackTrace stack)? onParseError,
    void Function(Object error, StackTrace stack)? onStreamError,
    void Function()? onReconnectExhausted,
  });

  /// streamChatMessages で立てた接続を明示的に切断する。アカウント切り替え
  /// 時などライフサイクルが複数 listener を超えて変わる場面で呼ぶ。
  void disposeChatStream();

  // === chat rooms (#438) =====================================================
  //
  // ルーム (グループチャット) は DM と同じ ChatMessage 型を使う。DM ・ルームの
  // 識別は ChatMessage.isRoomMessage で行う。サーバーがルーム機能自体に対応
  // していない場合 (Misskey でないアダプタ) はデフォルト実装が
  // UnsupportedError を投げる。

  /// 自分が参加しているルームスレッドの履歴 (1 ルーム = 1 スレッド、最新メッセージを
  /// 同梱)。Misskey の `/api/chat/history?room=true` 相当。
  ///
  /// 戻り値の [ChatThread] は `isRoom == true` で `room` が populate されている。
  Future<List<ChatThread>> getRoomHistory({TimelineQuery? query}) async =>
      throw UnsupportedError('rooms are not supported by this backend');

  /// 自分が参加しているルーム一覧 (最終メッセージは含まず、ルーム本体のみ)。
  Future<List<ChatRoom>> getJoiningRooms({TimelineQuery? query}) async =>
      throw UnsupportedError('rooms are not supported by this backend');

  /// 自分が所有しているルーム一覧 (作成者 = self)。
  Future<List<ChatRoom>> getOwnedRooms({TimelineQuery? query}) async =>
      throw UnsupportedError('rooms are not supported by this backend');

  /// 指定ルームの情報を取得。
  Future<ChatRoom> getRoom(String roomId) async =>
      throw UnsupportedError('rooms are not supported by this backend');

  /// 新規ルームを作成する。
  Future<ChatRoom> createRoom({
    required String name,
    String? description,
  }) async => throw UnsupportedError('rooms are not supported by this backend');

  /// ルーム情報を更新する (オーナーのみ)。
  Future<ChatRoom> updateRoom({
    required String roomId,
    String? name,
    String? description,
  }) async => throw UnsupportedError('rooms are not supported by this backend');

  /// ルームを削除する (オーナーのみ)。
  Future<void> deleteRoom(String roomId) async =>
      throw UnsupportedError('rooms are not supported by this backend');

  /// ルームに参加する (招待を受けている場合 / 公開ルームの場合)。
  Future<void> joinRoom(String roomId) async =>
      throw UnsupportedError('rooms are not supported by this backend');

  /// ルームから退出する。
  Future<void> leaveRoom(String roomId) async =>
      throw UnsupportedError('rooms are not supported by this backend');

  /// ルームのメンバー一覧を取得する。
  Future<List<ChatRoomMember>> getRoomMembers({
    required String roomId,
    TimelineQuery? query,
  }) async => throw UnsupportedError('rooms are not supported by this backend');

  /// 指定ルームのメッセージ一覧 (timeline)。
  Future<List<ChatMessage>> getRoomMessages({
    required String roomId,
    TimelineQuery? query,
  }) async => throw UnsupportedError('rooms are not supported by this backend');

  /// ルーム宛にメッセージを送信する。
  Future<ChatMessage> sendRoomMessage({
    required String roomId,
    String? text,
    String? fileId,
  }) async => throw UnsupportedError('rooms are not supported by this backend');

  /// ルームのミュート / アンミュート (自分の view から)。
  Future<void> setRoomMute({
    required String roomId,
    required bool mute,
  }) async => throw UnsupportedError('rooms are not supported by this backend');

  /// ユーザーをルームに招待する (オーナーのみ)。
  Future<void> inviteToRoom({
    required String roomId,
    required String userId,
  }) async => throw UnsupportedError('rooms are not supported by this backend');

  /// 自分宛の招待を無視する (受信箱から取り除く)。
  Future<void> ignoreInvitation(String roomId) async =>
      throw UnsupportedError('rooms are not supported by this backend');

  /// 自分宛の招待受信箱。
  Future<List<ChatRoomInvitation>> getInvitationInbox({
    TimelineQuery? query,
  }) async => throw UnsupportedError('rooms are not supported by this backend');

  /// 自分が送った招待の送信箱。
  Future<List<ChatRoomInvitation>> getInvitationOutbox({
    TimelineQuery? query,
  }) async => throw UnsupportedError('rooms are not supported by this backend');

  /// 特定ルームの新着メッセージを通知するストリーム。Misskey の
  /// `chatRoom` channel + `{roomId}` param 相当。listen で接続、onCancel で切断。
  Stream<ChatMessage> streamRoomMessages({
    required String roomId,
    void Function(Object error, StackTrace stack)? onParseError,
    void Function(Object error, StackTrace stack)? onStreamError,
    void Function()? onReconnectExhausted,
  }) => const Stream.empty();

  /// streamRoomMessages で立てた接続を明示的に切断する。
  void disposeRoomChatStream({String? roomId}) {}
}

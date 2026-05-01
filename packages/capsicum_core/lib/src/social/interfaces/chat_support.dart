import '../../model/chat_message.dart';
import '../../model/chat_thread.dart';
import '../../model/timeline_query.dart';

abstract mixin class ChatSupport {
  /// 現アカウントが chat を利用可能か。サーバー側のロール policy に応じて
  /// 'unavailable' なら false を返し、ドロワー gate に使う。getMyself 後に
  /// 確定する。実装が override しなければ true（互換挙動）。
  bool get canUseChat => true;

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
  Stream<ChatMessage> streamChatMessages();

  /// streamChatMessages で立てた接続を明示的に切断する。アカウント切り替え
  /// 時などライフサイクルが複数 listener を超えて変わる場面で呼ぶ。
  void disposeChatStream();
}

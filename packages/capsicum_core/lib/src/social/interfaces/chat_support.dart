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
}

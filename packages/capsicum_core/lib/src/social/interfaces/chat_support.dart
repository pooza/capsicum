import '../../model/chat_message.dart';
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
}

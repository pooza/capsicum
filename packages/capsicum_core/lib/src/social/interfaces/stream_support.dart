import '../../model/post.dart';
import '../../model/stream_connection_state.dart';
import '../../model/timeline_type.dart';

abstract mixin class StreamSupport {
  /// Returns a stream of new posts for the given timeline type.
  ///
  /// [onParseError] は実装内部で raw payload の JSON parse / 型変換に失敗した
  /// ときに呼ばれる任意コールバック。サーバー schema 変更を観測するため、
  /// 呼び出し側 (capsicum 本体) で Sentry 計装に繋げる用途を想定 (#586)。
  ///
  /// [onStreamError] は接続層 (TLS / DNS / WebSocket abort 等) で発生した
  /// error を観測層に流すための任意コールバック。null なら無視 (#586)。
  ///
  /// [onReconnectExhausted] は再接続上限に到達して諦めたときに 1 回だけ
  /// 呼ばれる。UI 警告や Sentry captureMessage に繋ぐ用途を想定 (#586)。
  ///
  /// [onConnectionState] は接続ライフサイクル (connecting / live / disconnected
  /// / exhausted) の遷移ごとに呼ばれる。常時の接続インジケータを出す用途を
  /// 想定 (#714)。同じ状態が連続するときは重複通知しない。
  ///
  /// [onDisconnect] は WebSocket が onDone で閉じたときに closeCode / closeReason
  /// とともに呼ばれる。本番でどんな切れ方をしているか (1000 / 1001 / 1006 …) を
  /// Sentry で観測する用途を想定 (#788)。null なら無視。
  Stream<Post> streamTimeline(
    TimelineType type, {
    void Function(Object error, StackTrace stack)? onParseError,
    void Function(Object error, StackTrace stack)? onStreamError,
    void Function()? onReconnectExhausted,
    void Function(StreamConnectionState state)? onConnectionState,
    void Function(int? closeCode, String? closeReason)? onDisconnect,
  });

  /// Closes the current streaming connection.
  void disposeStream();
}

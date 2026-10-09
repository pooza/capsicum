/// 通知の未読数を、サーバーが数えた値で返す (#1207)。
///
/// ⚠ **クライアント側では数えない。**取得した範囲しか見えないうえ、WebUI や
/// 他クライアントで読んだぶんが反映されない。
///
/// ⚠ 値が意味を持つのは、capsicum が既読をサーバーへ返しているから
/// （Mastodon は `MarkerSupport`・Misskey は `NotificationReadSupport`）。返さない
/// と「capsicum で読んでも減らない数」になる。
abstract mixin class NotificationUnreadCountSupport {
  Future<int> getUnreadNotificationCount();
}

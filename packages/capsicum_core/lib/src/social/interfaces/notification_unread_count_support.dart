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

/// このサーバーでは未読数の口が使えないと分かった (#1370)。
///
/// アダプターは**最初の 1 回だけ**これを投げ、以後は問い合わせずに 0 を返す。
/// 呼び出し側はこれを受けたときに、どのサーバーかを記録する（打ち続けていた
/// 間は、パンくずに host が残らず切り分けられなかった）。
class NotificationUnreadCountUnavailable implements Exception {
  const NotificationUnreadCountUnavailable(this.status);

  /// サーバーが返した HTTP status。
  final int status;

  @override
  String toString() => 'NotificationUnreadCountUnavailable($status)';
}

/// 通知の既読を「全部」の単位でしかサーバーへ返せないバックエンド (#1205)。
///
/// Misskey は通知の既読を `isRead` の 2 値で持ち、「ここまで読んだ」という
/// 位置を持たない。位置で返せる Mastodon は `MarkerSupport` を使う。
///
/// ⚠⚠ **呼ぶのは、利用者が一覧の先頭（一番新しい通知）を実際に見たときだけ。**
/// 取得しただけ・裏で更新しただけでは呼ばない。呼ぶと WebUI や他クライアント
/// の未読が消えるので、見ていないのに呼ぶと「黙って消える」(#1045) に戻る。
///
/// ⚠ 逆に一度も呼ばないと、capsicum だけで通知を読んでいる利用者は WebUI の
/// 未読が永久に消えない（取得側は `markAsRead: false` で止めてあるため）。
abstract mixin class NotificationReadSupport {
  Future<void> markAllNotificationsRead();
}

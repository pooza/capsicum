import '../../model/notification.dart';

/// 新規通知 (お知らせ含む) を WebSocket streaming からライブ配信する mixin (#569)。
///
/// timeline 用の [StreamSupport] とは独立した別接続を想定する。timeline
/// streaming は home_screen の lifecycle に縛られているため、通知の発火を
/// 画面表示中に限定させないよう専用の長寿命接続を持つ。adapter は両方を
/// mix-in しうる。
///
/// 主にデスクトップ 3 OS (macOS / Linux / Windows) で、アプリ起動中の通知を
/// OS ローカル通知へ橋渡しする `DesktopNotificationDispatcher` が購読する。
/// 設計は docs/desktop-notification-design.md を参照。
abstract mixin class NotificationStreamSupport {
  /// 新規通知を emit する broadcast ストリーム。
  ///
  /// 接続が切れた場合は実装内部で自動再接続を試み、上位には開いた状態のまま
  /// に見せる ([StreamSupport] と同じ reconnect / backoff 機構を流用)。
  /// [disposeNotificationStream] / dispose 時にクローズする。
  ///
  /// 内部の parse / 接続 error と再接続枯渇は [StreamSupport.streamTimeline] と
  /// 同型のコールバックで観測層へ流す。raw payload を捨てる前に拾えるよう
  /// streaming 実装の内側から呼ばれる (#569 観測性。timeline は #586 で対応済)。
  Stream<Notification> streamNotifications({
    void Function(Object error, StackTrace stack)? onParseError,
    void Function(Object error, StackTrace stack)? onStreamError,
    void Function()? onReconnectExhausted,
  });

  /// 通知ストリーミング接続を明示的にクローズする（アカウント切替 / dispose 時）。
  ///
  /// 通常の teardown は購読側（`DesktopNotificationDispatcher`）が
  /// [streamNotifications] の subscription を cancel し、broadcast controller の
  /// `onCancel` が streaming 実装の `dispose` を呼ぶ経路で完結する。再ログイン時も
  /// 新しい adapter が作られるため、本メソッドは実運用では呼ばれない防御的経路
  /// （明示破棄したい呼び出し元向けの契約）である (#676 で確認)。
  void disposeNotificationStream();
}

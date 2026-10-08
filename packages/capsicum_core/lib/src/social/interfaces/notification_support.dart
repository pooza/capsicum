import '../../model/notification.dart';
import '../../model/notification_query.dart';
import '../../model/notification_response.dart';
import '../../model/timeline_query.dart';

abstract mixin class NotificationSupport {
  /// [query] はページング、[filter] は絞り込みとグループ化 (#1042 / #1048)。
  ///
  /// ⚠ **[filter] を渡さない呼び出しは従来どおり**「全種別・非グループ」で取る。
  /// バックグラウンド取得や未読数の計算はこちらのまま使うこと（#1042 の
  /// 「サーバー側で絞ると未読の総数の意味が変わる」）。
  Future<NotificationResponse> getNotifications({
    TimelineQuery? query,
    NotificationQuery? filter,
  });

  /// このサーバーで絞り込みの候補に出せる種別 (#1042)。
  ///
  /// ⚠⚠ **アダプタが正本。**「どの種別に送信名があるか」はアダプタのマッピングが
  /// 知っていることなので、UI 側で SNS ごとに列挙し直さない（二重管理になり、
  /// 片方だけ増えると「チェックしても効かない項目」ができる）。
  ///
  /// ⚠ [NotificationType.other] は含めない。サーバー側の名前を列挙できないので
  /// 除外指定が効かせられない。
  Set<NotificationType> get filterableNotificationTypes;

  Future<void> clearAllNotifications();
}

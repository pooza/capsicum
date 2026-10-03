import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../platform/notification_subsystem/notification_subsystem.dart';
import '../provider/entitlement_status_provider.dart';

/// 支払いが止まっていることを、起動時にローカル通知で知らせる (#1123)。
///
/// ⚠⚠ **プッシュでは知らせられない。**未払いの間 relay は `/push` を拒むので
/// （capsicum-relay#63 の判断）、**通知が止まっていること自体をプッシュで伝える
/// ことができない**。⚠ 気づける経路は「アプリを開いたとき」しかないので、
/// **relay を通さないローカル通知**で出す。
///
/// ⚠ **出すのは未払い（[EntitlementView.grace]）だけ。**失効は利用者が自分で
/// 解約した結果であることが多く、毎回鳴らすと嫌がらせになる。未払いは
/// **カードの有効期限切れのように本人に悪意が無い**形で起きるので、知らせる価値が
/// ある（2026-10-03 pooza「カードの期限切れなどがある」）。
class EntitlementNoticeService {
  /// 最後に知らせた状態。⚠ **同じ状態で鳴らし続けないため**に持つ。
  static const lastNoticeKey = 'entitlement.last_notified_view';

  /// 他の通知と衝突しない固定 id。⚠ **固定なのは差し替えたいから** ——
  /// 起動のたびに積み上がると通知センターが同じ文面で埋まる。
  static const notificationId = 0x6361_7073 & 0x7fffffff;

  /// タップで登録ステータス画面へ送るための payload。
  ///
  /// ⚠ `main.dart` の `_routeFromNotificationPayload` が解釈する形に合わせる。
  /// ⚠⚠ **知らない `type` は通知タブへ落ちる**ので、増やすときは向こうも直す。
  static String payloadForSettings() =>
      jsonEncode({'type': 'entitlement_unpaid'});

  /// 必要なら通知を出す。**出したら true。**
  ///
  /// ⚠ **プリセットのアカウントを持っていれば出さない。**あの人たちは利用権が
  /// 要らない（画面の [showEntitlementSection] と同じ線）。
  ///
  /// ⚠ **状態が変わったら記録を消す。**直ったあとで再び未払いになったら、
  /// もう一度知らせる必要がある。
  static Future<bool> notifyIfNeeded({
    required EntitlementView view,
    required bool hasPreset,
    required NotificationSubsystem notifications,
    required SharedPreferences prefs,
  }) async {
    if (hasPreset) return false;
    if (view != EntitlementView.grace) {
      // ⚠ 未払い以外に落ち着いたら、次の未払いで鳴らせるように忘れる。
      await prefs.remove(lastNoticeKey);
      return false;
    }
    if (prefs.getString(lastNoticeKey) == view.name) return false;

    await notifications.show(
      id: notificationId,
      title: 'お支払いを確認できていません',
      body: 'プッシュ通知が止まっています。ストアでお支払い方法をご確認ください。',
      payload: payloadForSettings(),
    );
    await prefs.setString(lastNoticeKey, view.name);
    return true;
  }
}

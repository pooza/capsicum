import 'package:capsicum/src/platform/notification_subsystem/notification_subsystem.dart';
import 'package:capsicum/src/provider/entitlement_status_provider.dart';
import 'package:capsicum/src/service/entitlement_notice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 未払いを起動時のローカル通知で知らせる (#1123)。
///
/// ⚠⚠ **プッシュでは知らせられない。**未払いの間 relay は `/push` を拒むので
/// （capsicum-relay#63）、気づける経路は「アプリを開いたとき」しかない。
class _RecordingNotifications implements NotificationSubsystem {
  final List<({String title, String body, String? payload})> shown = [];

  @override
  Future<void> initialize({void Function(String? payload)? onTap}) async {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    NotificationCategory category = NotificationCategory.message,
  }) async {
    shown.add((title: title, body: body, payload: payload));
  }
}

void main() {
  late _RecordingNotifications notifications;

  setUp(() {
    notifications = _RecordingNotifications();
    SharedPreferences.setMockInitialValues({});
  });

  Future<bool> run(EntitlementView view, {bool hasPreset = false}) async {
    return EntitlementNoticeService.notifyIfNeeded(
      view: view,
      hasPreset: hasPreset,
      notifications: notifications,
      prefs: await SharedPreferences.getInstance(),
    );
  }

  test('未払いなら出す', () async {
    expect(await run(EntitlementView.grace), isTrue);
    expect(notifications.shown, hasLength(1));
    expect(notifications.shown.single.title, contains('お支払い'));
    // ⚠ 止まっていることを本文で言う（relay#63 の判断に合わせる）。
    expect(notifications.shown.single.body, contains('止まっています'));
  });

  // ⚠⚠ **起動のたびに鳴らさない。**同じ状態では 1 回だけ。
  test('同じ状態では 2 回目を出さない', () async {
    expect(await run(EntitlementView.grace), isTrue);
    expect(await run(EntitlementView.grace), isFalse);
    expect(notifications.shown, hasLength(1));
  });

  // ⚠ 直ったあとで再び未払いになったら、もう一度知らせる必要がある。
  test('一度直ってからまた未払いになれば、また出す', () async {
    expect(await run(EntitlementView.grace), isTrue);
    expect(await run(EntitlementView.active), isFalse);
    expect(await run(EntitlementView.grace), isTrue);
    expect(notifications.shown, hasLength(2));
  });

  // ⚠⚠ **プリセットの利用者には利用権が要らない**（画面の
  // showEntitlementSection と同じ線）。鳴らすと「買え」と言っているのと同じ。
  test('🔴 プリセットのアカウントがあれば、未払いでも出さない', () async {
    expect(await run(EntitlementView.grace, hasPreset: true), isFalse);
    expect(notifications.shown, isEmpty);
  });

  // ⚠ 失効は本人が解約した結果であることが多い。毎回鳴らすと嫌がらせになる。
  // ⚠⚠ **`values` から引く**（手で並べない）。状態は増えるので、列挙にすると
  // **新しい状態が検査から黙って漏れる** —— `refunded` を足したときに実際に
  // 漏れかけた。返金済みは**届いている**ので、鳴らす理由が無い。
  test('未払い以外では出さない', () async {
    for (final view in EntitlementView.values.where(
      (v) => v != EntitlementView.grace,
    )) {
      expect(await run(view), isFalse, reason: '$view');
    }
    expect(notifications.shown, isEmpty);
  });

  test('タップ payload は設定画面向けの type を持つ', () async {
    await run(EntitlementView.grace);

    expect(
      notifications.shown.single.payload,
      EntitlementNoticeService.payloadForSettings(),
    );
    expect(notifications.shown.single.payload, contains('entitlement_unpaid'));
  });
}

import 'package:capsicum/src/service/announcement_subscription_service.dart';
import 'package:capsicum/src/service/push_relay_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 永続化のセマンティクス (キー存在 = 有効、disable で削除) のみテスト。
/// HTTP は走らせず、enable / disable の relay 呼び出しは別途
/// インテグレーション検証で確認する。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // テスト間で汚染しないよう、毎回 default client に戻す。
    AnnouncementSubscriptionService.client = PushRelayClient();
  });

  group('AnnouncementSubscriptionService.isEnabled', () {
    test('未登録のアカウントは false', () async {
      expect(
        await AnnouncementSubscriptionService.isEnabled('mastodon://a@h'),
        isFalse,
      );
    });

    test('id 保存後は true', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '${AnnouncementSubscriptionService.prefsKeyPrefix}mastodon://a@h': 42,
      });
      expect(
        await AnnouncementSubscriptionService.isEnabled('mastodon://a@h'),
        isTrue,
      );
    });
  });

  group('AnnouncementSubscriptionService.disable', () {
    test('保存済み id を削除し relay の DELETE を呼ぶ', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '${AnnouncementSubscriptionService.prefsKeyPrefix}mastodon://a@h': 99,
      });
      final fake = _FakeRelayClient();
      AnnouncementSubscriptionService.client = fake;

      await AnnouncementSubscriptionService.disable(
        'mastodon://a@h',
        host: 'h',
      );

      expect(fake.unregisteredIds, [99]);
      expect(
        await AnnouncementSubscriptionService.isEnabled('mastodon://a@h'),
        isFalse,
      );
    });

    test('id 未保存なら relay を呼ばず prefs だけ整える', () async {
      final fake = _FakeRelayClient();
      AnnouncementSubscriptionService.client = fake;

      await AnnouncementSubscriptionService.disable('mastodon://a@h');

      expect(fake.unregisteredIds, isEmpty);
      expect(
        await AnnouncementSubscriptionService.isEnabled('mastodon://a@h'),
        isFalse,
      );
    });

    test('relay 側エラーでもローカル削除は完了する (ユーザー視点 OFF)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '${AnnouncementSubscriptionService.prefsKeyPrefix}mastodon://a@h': 12,
      });
      final fake = _FakeRelayClient(throwOnUnregister: true);
      AnnouncementSubscriptionService.client = fake;

      await AnnouncementSubscriptionService.disable(
        'mastodon://a@h',
        host: 'h',
      );

      expect(fake.unregisteredIds, [12]);
      expect(
        await AnnouncementSubscriptionService.isEnabled('mastodon://a@h'),
        isFalse,
      );
    });

    test('explicit=false ではログアウト経路扱いで opt-out marker を立てない', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '${AnnouncementSubscriptionService.prefsKeyPrefix}mastodon://a@h': 5,
      });
      AnnouncementSubscriptionService.client = _FakeRelayClient();

      await AnnouncementSubscriptionService.disable('mastodon://a@h');

      expect(
        await AnnouncementSubscriptionService.isExplicitlyOptedOut(
          'mastodon://a@h',
        ),
        isFalse,
      );
    });

    test('explicit=true は opt-out marker を立てて auto-enable をブロックする', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '${AnnouncementSubscriptionService.prefsKeyPrefix}mastodon://a@h': 7,
      });
      AnnouncementSubscriptionService.client = _FakeRelayClient();

      await AnnouncementSubscriptionService.disable(
        'mastodon://a@h',
        explicit: true,
      );

      expect(
        await AnnouncementSubscriptionService.isExplicitlyOptedOut(
          'mastodon://a@h',
        ),
        isTrue,
      );
    });
  });

  group('AnnouncementSubscriptionService.isExplicitlyOptedOut', () {
    test('marker が無ければ false', () async {
      expect(
        await AnnouncementSubscriptionService.isExplicitlyOptedOut(
          'mastodon://a@h',
        ),
        isFalse,
      );
    });

    test('marker が立っていれば true', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '${AnnouncementSubscriptionService.prefsKeyOptOutPrefix}mastodon://a@h':
            true,
      });
      expect(
        await AnnouncementSubscriptionService.isExplicitlyOptedOut(
          'mastodon://a@h',
        ),
        isTrue,
      );
    });
  });
}

class _FakeRelayClient extends PushRelayClient {
  _FakeRelayClient({this.throwOnUnregister = false});

  final bool throwOnUnregister;
  final List<int> unregisteredIds = [];

  @override
  Future<void> unregisterAnnouncementSubscription(int id) async {
    unregisteredIds.add(id);
    if (throwOnUnregister) {
      throw DioException(
        requestOptions: RequestOptions(path: '/announcement_subscriptions/$id'),
        type: DioExceptionType.connectionError,
      );
    }
  }
}

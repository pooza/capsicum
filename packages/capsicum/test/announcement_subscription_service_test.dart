import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/service/announcement_subscription_service.dart';
import 'package:capsicum/src/service/push_relay_client.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
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

  group('AnnouncementSubscriptionService.autoEnableIfDefault', () {
    // 非対応 = Windows / Linux。macOS は #919 で対応側へ移った。
    test('非対応プラットフォームでは既存の自動購読を片付ける', () async {
      AnnouncementSubscriptionService.debugPlatformSupportedOverride = false;
      addTearDown(() {
        AnnouncementSubscriptionService.debugPlatformSupportedOverride = null;
      });
      SharedPreferences.setMockInitialValues(<String, Object>{
        '${AnnouncementSubscriptionService.prefsKeyPrefix}mastodon://a@h': 7,
      });
      final fake = _FakeRelayClient();
      AnnouncementSubscriptionService.client = fake;

      await AnnouncementSubscriptionService.autoEnableIfDefault(
        _makeAccount('a', 'h'),
      );

      expect(fake.unregisteredIds, [7]);
      expect(
        await AnnouncementSubscriptionService.isEnabled('mastodon://a@h'),
        isFalse,
      );
    });

    test('非対応プラットフォームで購読が無ければ何もしない', () async {
      AnnouncementSubscriptionService.debugPlatformSupportedOverride = false;
      addTearDown(() {
        AnnouncementSubscriptionService.debugPlatformSupportedOverride = null;
      });
      final fake = _FakeRelayClient();
      AnnouncementSubscriptionService.client = fake;

      await AnnouncementSubscriptionService.autoEnableIfDefault(
        _makeAccount('a', 'h'),
      );

      expect(fake.unregisteredIds, isEmpty);
    });
  });

  group('AnnouncementSubscriptionService.hasLocalState', () {
    test('id も opt-out marker も無ければ false', () async {
      expect(
        await AnnouncementSubscriptionService.hasLocalState('mastodon://a@h'),
        isFalse,
      );
    });

    test('subscription id だけ存在 (auto-enable 済み) なら true', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '${AnnouncementSubscriptionService.prefsKeyPrefix}mastodon://a@h': 42,
      });
      expect(
        await AnnouncementSubscriptionService.hasLocalState('mastodon://a@h'),
        isTrue,
      );
    });

    test('opt-out marker だけ存在 (明示 OFF 済み) なら true', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '${AnnouncementSubscriptionService.prefsKeyOptOutPrefix}mastodon://a@h':
            true,
      });
      expect(
        await AnnouncementSubscriptionService.hasLocalState('mastodon://a@h'),
        isTrue,
      );
    });
  });
}

class _MockAdapter extends Mock implements DecentralizedBackendAdapter {}

class _MockUser extends Mock implements User {}

class _MockUserSecret extends Mock implements UserSecret {}

/// autoEnableIfDefault に渡す最小限の Account。非対応プラットフォーム分岐は
/// account.key しか参照しないため adapter 等は mock で足りる。
Account _makeAccount(String username, String host) => Account(
  key: AccountKey(type: BackendType.mastodon, host: host, username: username),
  adapter: _MockAdapter(),
  user: _MockUser(),
  userSecret: _MockUserSecret(),
);

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

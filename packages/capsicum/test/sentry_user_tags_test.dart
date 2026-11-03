import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/entitlement_status_provider.dart';
import 'package:capsicum/src/service/sentry_user_tags.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('relayEntitlementTagOf (#1358)', () {
    String? tagOf(
      EntitlementView view, {
      String? status,
      bool loading = false,
    }) => relayEntitlementTagOf(
      EntitlementStatus(view: view, relayStatus: status, isRefreshing: loading),
    );

    test('購入者と読む値は active と grace だけで、unverified は分かれる', () {
      expect(tagOf(EntitlementView.active, status: 'active'), 'active');
      expect(tagOf(EntitlementView.grace, status: 'grace'), 'grace');
      expect(tagOf(EntitlementView.active, status: 'unverified'), 'unverified');
    });

    test('relay の知らない値はそのまま出さず other に丸める', () {
      expect(tagOf(EntitlementView.active, status: 'token-abc'), 'other');
      expect(tagOf(EntitlementView.active), 'other');
    });

    test('読み込み中の初期値はタグを付けず、読めたあとの未購入は none', () {
      expect(tagOf(EntitlementView.absent, loading: true), isNull);
      expect(tagOf(EntitlementView.absent), 'none');
    });

    test('残りの状態はそれぞれの名前', () {
      expect(tagOf(EntitlementView.preset), 'preset');
      expect(tagOf(EntitlementView.unknown), 'unknown');
      expect(tagOf(EntitlementView.refunded), 'refunded');
      expect(tagOf(EntitlementView.expired), 'expired');
    });
  });

  group('sentryUserTagsProvider (#1358)', () {
    late Map<String, String> written;
    late void Function(String, String) original;

    setUp(() {
      written = {};
      original = sentryUserTagWriter;
      sentryUserTagWriter = (key, value) => written[key] = value;
    });
    tearDown(() => sentryUserTagWriter = original);

    test('読むまでは書かず、読んだ時点の値を書き、変われば書き直す', () {
      final hasPreset = StateProvider<bool>((_) => true);
      final container = ProviderContainer(
        overrides: [
          hasPresetAccountProvider.overrideWith((ref) => ref.watch(hasPreset)),
        ],
      );
      addTearDown(container.dispose);

      expect(written, isEmpty);

      container.read(sentryUserTagsProvider);
      expect(written[presetUserTag], 'true');

      container.read(hasPreset.notifier).state = false;
      container.read(hasPresetAccountProvider);
      expect(written[presetUserTag], 'false');
    });

    test('writeRelayEntitlementTag は読めていない回に書かない', () {
      writeRelayEntitlementTag(const EntitlementStatus(isRefreshing: true));
      expect(written, isEmpty);

      writeRelayEntitlementTag(const EntitlementStatus());
      expect(written[relayEntitlementTag], 'none');
    });
  });
}

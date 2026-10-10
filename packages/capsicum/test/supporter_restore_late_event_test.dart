import 'dart:async';

import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/supporter_purchase_backend.dart';
import 'package:capsicum/src/provider/supporter_purchase_provider.dart';
import 'package:capsicum/src/provider/supporter_status_provider.dart';
import 'package:capsicum/src/service/device_install_id.dart';
import 'package:capsicum/src/service/push_relay_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1237: 「購入を復元する」の結果が一瞬矛盾する・発行中にもう一度押せる。
///
/// 復元の要求が返ったあとで購入イベントが届き、relay での発行に数秒かかると:
/// - 先に「復元できる購入はありません」が出て、あとから「復元しました」で上書き
/// - 発行のあいだボタンが戻っていて、押し直すと 2 本目の発行が 1 本目と枠を取り合う
///
/// ⚠ サブスクを扱える OS でしか通らない経路（`subscriptionPurchaseSupported`）
/// なので、扱えないホスト（CI の Linux）では飛ばす。手元の macOS で回る。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _fallbackOutcomeTests();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> store;

  setUp(() {
    DeviceInstallId.resetForTest();
    SharedPreferences.setMockInitialValues({});
    store = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
          final key = args['key'] as String?;
          switch (call.method) {
            case 'write':
              store[key!] = args['value'] as String;
              return null;
            case 'read':
              return store[key!];
            case 'delete':
              store.remove(key!);
              return null;
            case 'containsKey':
              return store.containsKey(key!);
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  ({ProviderContainer container, _Backend backend, _Relay relay}) setUpAll() {
    final backend = _Backend();
    final relay = _Relay();
    final container = ProviderContainer(
      overrides: [
        supporterPurchaseBackendProvider.overrideWithValue(backend),
        supporterRelayClientProvider.overrideWithValue(relay),
        accountManagerProvider.overrideWith(_NoAccounts.new),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, backend: backend, relay: relay);
  }

  Future<void> turn() => Future<void>.delayed(Duration.zero);

  test(
    '⚠⚠ 発行の途中は「復元できる購入はありません」を出さず、ボタンも戻さない',
    () async {
      final (:container, :backend, :relay) = setUpAll();
      final notifier = container.read(supporterPurchaseProvider.notifier);
      await turn();

      // 復元の要求の最中に購入イベントが届き、発行は relay の応答待ちで止まる。
      backend.emitOnRestore = true;
      final returned = await notifier.restoreAndReregister();
      expect(returned, isTrue, reason: '前提: 復元で購入が返った');
      // 発行はインストール ID の読み出しを挟んでから relay へ出る。
      await turn();
      await turn();
      expect(relay.issuing, isNotNull, reason: '前提: 発行が始まっている');

      final during = container.read(supporterPurchaseProvider);
      expect(
        during.lastOutcome?.kind,
        isNot(SupporterPurchaseOutcomeKind.nothingToRestore),
        reason: '⚠ 直す前は、ここで「復元できる購入はありません」が出ていた',
      );
      expect(
        during.purchaseInProgress,
        isTrue,
        reason: '⚠ 直す前は戻っていて、もう一度「復元」を押せた',
      );

      // relay が答えたら、成功として終わる。
      relay.issuing!.complete({'token': 't', 'store': 'apple'});
      await turn();
      await turn();
      final after = container.read(supporterPurchaseProvider);
      expect(after.lastOutcome?.kind, SupporterPurchaseOutcomeKind.success);
      expect(after.purchaseInProgress, isFalse);
    },
    skip: subscriptionPurchaseSupported ? false : 'サブスクを扱えないホスト',
  );

  test(
    '⚠⚠ 発行が済んだあとの後始末の最中に復元が返っても、ボタンが戻る',
    () async {
      // v2.1 のリリース前レビュー（2026-10-10）。発行の出口がフラグを戻したあと、
      // 復元の側が「まだ処理中のイベントがある」と見て立て直すと、戻す者が
      // 居なくなり、購入も復元も再起動まで押せなくなっていた。
      final (:container, :backend, :relay) = setUpAll();
      final notifier = container.read(supporterPurchaseProvider.notifier);
      await turn();

      backend.emitOnRestore = true;
      backend.restoreGate = Completer<void>();
      backend.completeGate = Completer<void>();
      final restoring = notifier.restoreAndReregister();
      await turn();
      await turn();
      expect(relay.issuing, isNotNull, reason: '前提: 発行が始まっている');

      // 発行は済み、ストアの確定（後始末）で止まっている。
      relay.issuing!.complete({'token': 't', 'store': 'apple'});
      await turn();
      await turn();
      expect(backend.completeCalls, 1, reason: '前提: 後始末まで進んでいる');
      expect(
        container.read(supporterPurchaseProvider).purchaseInProgress,
        isTrue,
        reason: '⚠ 後始末（ストアの確定と登録のやり直し）が済むまで押させない',
      );

      // ここで復元の要求が返る（処理中のイベントが 1 件ある状態）。
      backend.restoreGate!.complete();
      expect(await restoring, isTrue);

      // 後始末が終わったら、ボタンは戻っている。
      backend.completeGate!.complete();
      await turn();
      await turn();
      final after = container.read(supporterPurchaseProvider);
      expect(after.lastOutcome?.kind, SupporterPurchaseOutcomeKind.success);
      expect(
        after.purchaseInProgress,
        isFalse,
        reason: '⚠ 直す前は true のまま残り、再起動まで押せなかった',
      );
    },
    skip: subscriptionPurchaseSupported ? false : 'サブスクを扱えないホスト',
  );

  test(
    '前提: 購入が 1 つも返らなければ「復元できる購入はありません」',
    () async {
      final (:container, backend: _, relay: _) = setUpAll();
      final notifier = container.read(supporterPurchaseProvider.notifier);
      await turn();

      await notifier.restoreAndReregister();
      final state = container.read(supporterPurchaseProvider);
      expect(
        state.lastOutcome?.kind,
        SupporterPurchaseOutcomeKind.nothingToRestore,
      );
      expect(state.purchaseInProgress, isFalse);
    },
    skip: subscriptionPurchaseSupported ? false : 'サブスクを扱えないホスト',
  );
}

// ⚠ 上の 2 本と違い、こちらはホストに依らず回る（判定だけを見る）。
void _fallbackOutcomeTests() {
  group('outcomeAfterRestoreFallback', () {
    const success = SupporterPurchaseOutcome(
      SupporterPurchaseOutcomeKind.success,
      isSubscription: true,
    );

    test('購入が届いていなければ「復元できる購入はありません」', () {
      expect(
        outcomeAfterRestoreFallback(null, arrivedLate: false)?.kind,
        SupporterPurchaseOutcomeKind.nothingToRestore,
      );
    });

    test('⚠⚠ 遅れて届いていたら、何も立てない（発行の結果に任せる）', () {
      expect(outcomeAfterRestoreFallback(null, arrivedLate: true), isNull);
    });

    test('既に立っている結果は上書きしない', () {
      expect(outcomeAfterRestoreFallback(success, arrivedLate: false), success);
      expect(outcomeAfterRestoreFallback(success, arrivedLate: true), success);
    });
  });
}

class _NoAccounts extends AccountManagerNotifier {
  @override
  AccountManagerState build() => const AccountManagerState();
}

/// 復元の要求はすぐ返し、購入イベントは呼ばれたときに流すストア。
class _Backend implements SupporterPurchaseBackend {
  final _events = StreamController<SupporterPurchaseEvent>.broadcast();

  void emitSubscriptionPurchased() => _events.add(
    const SupporterPurchaseEvent(
      productId: supporterSubscriptionProductId,
      status: SupporterPurchaseEventStatus.purchased,
      purchaseId: 'p1',
      needsCompletion: true,
    ),
  );

  @override
  bool get isSupported => true;

  @override
  Stream<SupporterPurchaseEvent> get purchaseEvents => _events.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<ProductDetails>> queryProducts(Set<String> ids) async => const [];

  @override
  Future<void> buy(ProductDetails product) async {}

  @override
  Future<void> buySubscription(ProductDetails product) async {}

  /// true なら、復元の要求の最中に購入イベントを流す。
  bool emitOnRestore = false;

  /// 立ててあれば、復元の要求はこれが済むまで返らない。
  Completer<void>? restoreGate;

  /// 立ててあれば、ストアの確定はこれが済むまで返らない。
  Completer<void>? completeGate;
  int completeCalls = 0;

  @override
  Future<void> restore() async {
    if (emitOnRestore) emitSubscriptionPurchased();
    await restoreGate?.future;
  }

  @override
  Future<void> complete(SupporterPurchaseEvent event) async {
    completeCalls++;
    await completeGate?.future;
  }

  @override
  void dispose() => _events.close();
}

/// 発行の応答を手で通す relay。
class _Relay extends PushRelayClient {
  Completer<Map<String, dynamic>>? issuing;

  @override
  Future<Map<String, dynamic>> issueEntitlementToken({
    required String store,
    required String purchaseId,
    required String deviceId,
    String? productId,
  }) => (issuing = Completer<Map<String, dynamic>>()).future;

  @override
  Future<Map<String, dynamic>?> fetchEntitlement(String token) async => null;
}

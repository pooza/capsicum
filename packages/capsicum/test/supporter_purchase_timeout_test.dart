import 'dart:async';

import 'package:capsicum/src/provider/supporter_purchase_backend.dart';
import 'package:capsicum/src/provider/supporter_purchase_provider.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// #1231: サポート画面のホイールが止まらず、投げ銭も利用権も出なかった。
///
/// ⚠⚠ **症状は 2 つに見えて原因は 1 つ。**読み込み中は節ごとホイールに
/// 差し替わるので、投げ銭と利用権がまとめて消える。⚠ しかも「再読み込み」は
/// `!isAvailable` の分岐にあるので、**読み込み中のままだと永久に出てこない**
/// （＝利用者にできることが無い）。

/// 何を聞かれても**返ってこない**ストア。
class _HangingBackend implements SupporterPurchaseBackend {
  final _events = StreamController<SupporterPurchaseEvent>.broadcast();

  @override
  bool get isSupported => true;

  @override
  Stream<SupporterPurchaseEvent> get purchaseEvents => _events.stream;

  // ⚠ 完了しない Future を返す（これが今回の事象そのもの）。
  @override
  Future<bool> isAvailable() => Completer<bool>().future;

  @override
  Future<List<ProductDetails>> queryProducts(Set<String> ids) =>
      Completer<List<ProductDetails>>().future;

  @override
  Future<void> buy(ProductDetails product) async {}

  @override
  Future<void> buySubscription(ProductDetails product) async {}

  @override
  Future<void> restore() async {}

  @override
  Future<void> complete(SupporterPurchaseEvent event) async {}

  @override
  void dispose() => _events.close();
}

/// [delay] だけ待たせてから答える、**遅いが返ってくる**ストア (#1248)。
///
/// Windows の backend と同じく、`isAvailable()` で取った商品を覚えておき、
/// `queryProducts()` はそれを即座に返す。
class _SlowBackend extends _HangingBackend {
  _SlowBackend(this.delay, {this.available = true});

  final Duration delay;
  final bool available;
  int availabilityCalls = 0;

  @override
  Future<bool> isAvailable() {
    availabilityCalls++;
    return Future<bool>.delayed(delay, () => available);
  }

  @override
  Future<List<ProductDetails>> queryProducts(Set<String> ids) async => [
    ProductDetails(
      id: supporterTipProductIds.first,
      title: 'tip',
      description: '',
      price: '¥100',
      rawPrice: 100,
      currencyCode: 'JPY',
    ),
  ];
}

void main() {
  group('#1248 時間切れのあとに届いた答えを捨てない', () {
    ProviderContainer containerWith(SupporterPurchaseBackend backend) {
      final container = ProviderContainer(
        overrides: [
          supporterPurchaseBackendProvider.overrideWithValue(backend),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('⚠⚠ 上限を過ぎてから「利用可能」と返ったら、入口を出す側へ戻す', () {
      fakeAsync((async) {
        final backend = _SlowBackend(const Duration(seconds: 40));
        final container = containerWith(backend);
        container.read(supporterPurchaseProvider);

        // 上限を過ぎた時点では、固着から抜けて「利用不可」（#1231 のまま）。
        async.elapse(
          SupporterPurchaseNotifier.storeTimeout + const Duration(seconds: 1),
        );
        var state = container.read(supporterPurchaseProvider);
        expect(state.isLoadingProducts, isFalse, reason: '前提: 固着していない');
        expect(state.isAvailable, isFalse, reason: '前提: いったん利用不可');

        // 🔴 直す前は、ここで答えが届いても永久に false のままだった。
        // Windows の「サポート」の入口は isAvailable だけで出し分けるので、
        // 入口ごと消えていた。
        async.elapse(const Duration(seconds: 30));
        state = container.read(supporterPurchaseProvider);
        expect(state.isAvailable, isTrue, reason: '遅れて届いた答えに従う');
        expect(state.products, hasLength(1), reason: '商品も出る');
        expect(state.isLoadingProducts, isFalse);
        // ⚠ 問い合わせ直していない（遅いストアで回り続けないこと）。
        expect(backend.availabilityCalls, 1);
      });
    });

    test('遅れて「利用不可」と返ったら、そのまま', () {
      fakeAsync((async) {
        final container = containerWith(
          _SlowBackend(const Duration(seconds: 40), available: false),
        );
        container.read(supporterPurchaseProvider);

        async.elapse(const Duration(seconds: 60));
        final state = container.read(supporterPurchaseProvider);
        expect(state.isAvailable, isFalse);
        expect(state.products, isEmpty);
      });
    });

    test('⚠ 待っている間に読み直しが始まっていたら、古い答えは使わない', () {
      fakeAsync((async) {
        final backend = _SlowBackend(const Duration(seconds: 40));
        final container = containerWith(backend);
        container.read(supporterPurchaseProvider);

        // 1 回目が時間切れ（16 秒）。20 秒の時点で読み直す。
        async.elapse(const Duration(seconds: 20));
        unawaited(
          container.read(supporterPurchaseProvider.notifier).loadProducts(),
        );
        // 30 秒: 読み直しはまだ上限の手前 ＝ 読み込み中。
        async.elapse(const Duration(seconds: 10));
        expect(
          container.read(supporterPurchaseProvider).isLoadingProducts,
          isTrue,
          reason: '前提: 2 回目が進行中',
        );

        // 41 秒: 1 回目の答えが届く。⚠ 2 回目が進行中なので、ここで
        // 「読み込み完了」にしてはいけない。
        async.elapse(const Duration(seconds: 11));
        final state = container.read(supporterPurchaseProvider);
        expect(state.isAvailable, isFalse, reason: '古い世代の答えは反映しない');
        expect(state.isLoadingProducts, isFalse, reason: '2 回目も時間切れ（36 秒）');

        // 61 秒: 2 回目の答えが届く ＝ こちらは最新の世代なので反映する。
        async.elapse(const Duration(seconds: 20));
        expect(container.read(supporterPurchaseProvider).isAvailable, isTrue);
      });
    });
  });

  test('⚠⚠ ストアが返ってこなくても、ホイールのまま固着しない', () {
    fakeAsync((async) {
      final container = ProviderContainer(
        overrides: [
          supporterPurchaseBackendProvider.overrideWithValue(_HangingBackend()),
        ],
      );
      addTearDown(container.dispose);

      // build() が scheduleMicrotask(loadProducts) を仕込む。
      expect(
        container.read(supporterPurchaseProvider).isLoadingProducts,
        isTrue,
        reason: '最初は読み込み中',
      );

      // ⚠ タイムアウトの手前では、まだ回っている（ここを縮めない）。
      async.elapse(
        SupporterPurchaseNotifier.storeTimeout - const Duration(seconds: 1),
      );
      expect(
        container.read(supporterPurchaseProvider).isLoadingProducts,
        isTrue,
        reason: '⚠ 早すぎる打ち切りは、遅い回線を切ることになる',
      );

      // 🔴 直す前はここで永久に true のままだった。
      async.elapse(const Duration(seconds: 2));
      final state = container.read(supporterPurchaseProvider);
      expect(state.isLoadingProducts, isFalse, reason: 'ホイールから抜ける');
      // ⚠⚠ **抜け道が出る。**「再読み込み」は `!isAvailable` の分岐にある。
      expect(state.isAvailable, isFalse, reason: '再読み込みの口が出る側へ倒す');
    });
  });

  test('⚠ 上限は、実測の往復（Play 345ms / Apple 1,084ms）より十分に長い', () {
    expect(
      SupporterPurchaseNotifier.storeTimeout,
      greaterThan(const Duration(seconds: 5)),
      reason: '⚠ 短すぎる上限は、遅い回線の利用者を切る',
    );
    // ⚠ 長すぎると「固着」と見分けがつかない。
    expect(
      SupporterPurchaseNotifier.storeTimeout,
      lessThanOrEqualTo(const Duration(seconds: 30)),
    );
  });
}

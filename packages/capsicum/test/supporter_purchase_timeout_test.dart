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

void main() {
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

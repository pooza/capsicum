import 'package:capsicum/src/provider/supporter_purchase_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('supporterTipProductIds (#428 B-2)', () {
    test('3 階層・前方互換命名・金額昇順', () {
      expect(supporterTipProductIds, [
        'supporter.tip.small',
        'supporter.tip.medium',
        'supporter.tip.big',
      ]);
    });
  });

  group('SupporterPurchaseState.copyWith — lastOutcome sentinel', () {
    test('引数省略で lastOutcome を維持する', () {
      const s = SupporterPurchaseState(
        lastOutcome: SupporterPurchaseOutcome(
          SupporterPurchaseOutcomeKind.success,
        ),
      );
      final next = s.copyWith(purchaseInProgress: true);
      expect(next.lastOutcome?.kind, SupporterPurchaseOutcomeKind.success);
      expect(next.purchaseInProgress, isTrue);
    });

    test('明示的に null を渡すとクリアする（再購入開始時の挙動）', () {
      const s = SupporterPurchaseState(
        lastOutcome: SupporterPurchaseOutcome(
          SupporterPurchaseOutcomeKind.error,
        ),
      );
      final next = s.copyWith(lastOutcome: null);
      expect(next.lastOutcome, isNull);
    });

    test('差し替えできる', () {
      const s = SupporterPurchaseState();
      final next = s.copyWith(
        lastOutcome: const SupporterPurchaseOutcome(
          SupporterPurchaseOutcomeKind.canceled,
        ),
      );
      expect(next.lastOutcome?.kind, SupporterPurchaseOutcomeKind.canceled);
    });

    test('既定状態は未試行・未利用', () {
      const s = SupporterPurchaseState();
      expect(s.isAvailable, isFalse);
      expect(s.products, isEmpty);
      expect(s.purchaseInProgress, isFalse);
      expect(s.lastOutcome, isNull);
    });
  });
  group('利用権サブスク (#1122)', () {
    test('SKU は単一・前方互換命名（supporter.*）', () {
      // ⚠ 階層を増やさない（設計書 決定済み事項 5 の「単一階層」）。
      expect(supporterSubscriptionProductId, 'supporter.relay.monthly');
    });

    // ⚠⚠ **投げ銭の SKU に混ぜない。**混ざると、投げ銭の一覧に利用権が並び、
    // 購入後の処理（markTipped）がサブスクにも走る。
    test('投げ銭の SKU 一覧に含めない', () {
      expect(
        supporterTipProductIds,
        isNot(contains(supporterSubscriptionProductId)),
      );
    });

    test('subscription は省略時に維持される', () {
      const s = SupporterPurchaseState(hasEntitlement: true);
      final next = s.copyWith(purchaseInProgress: true);
      expect(next.hasEntitlement, isTrue);
    });

    // ⚠⚠ **明示的に null を渡せること**が要。ストアから商品が消えた
    // （審査落ち・配信停止）ときに入口を引っ込められないと、
    // **押しても買えないボタン**が残る。
    test('subscription は明示的な null でクリアできる', () {
      const s = SupporterPurchaseState();
      final cleared = s.copyWith(subscription: null);
      expect(cleared.subscription, isNull);
    });

    test('hasEntitlement は省略時に維持される', () {
      const s = SupporterPurchaseState(hasEntitlement: true);
      expect(s.copyWith(isAvailable: true).hasEntitlement, isTrue);
    });
  });
}

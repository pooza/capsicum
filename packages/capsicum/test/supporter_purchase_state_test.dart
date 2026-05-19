import 'package:capsicum/src/provider/supporter_purchase_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('supporterTipProductIds (#428 B-2)', () {
    test('3 階層・前方互換命名・金額昇順', () {
      expect(supporterTipProductIds, [
        'supporter.tip.small',
        'supporter.tip.medium',
        'supporter.tip.large',
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
}

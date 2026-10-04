import 'dart:io';

import 'package:capsicum/src/provider/supporter_purchase_backend.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/source_files.dart';

/// #1220: relay へ送る `purchase_id` は**ストアで中身が違う**。
///
/// ⚠⚠ **2026-10-04 に本番で踏んだ。**Android でも `purchaseID`（＝ orderId）を
/// 送っていたため、Play の `purchases/subscriptionsv2/tokens/{token}` が 404 を
/// 返して利用権が `unverified` で止まり、**買った人がゲートに拒否された**
/// （`reason=no_entitlement`）。⚠ **RTDN も突き合わせられなかった**
/// （`RENEWED (unknown_purchase)`）—— あちらは purchaseToken で届く。
void main() {
  group('entitlementPurchaseIdFor', () {
    // ⚠⚠ **これが不具合の本体。**Google は purchaseToken でなければ引けない。
    test('google は serverVerificationData（purchaseToken）を送る', () {
      expect(
        entitlementPurchaseIdFor(
          store: 'google',
          purchaseId: 'GPA.3351-1234-5678-90123',
          serverVerificationData: 'opaque-purchase-token',
        ),
        'opaque-purchase-token',
      );
    });

    // ⚠ Apple 側を壊さないことの固定。transactionId を送り続ける。
    test('apple は purchaseID（transactionId）を送る', () {
      expect(
        entitlementPurchaseIdFor(
          store: 'apple',
          purchaseId: '2000000912345678',
          // ⚠ iOS の serverVerificationData は base64 のレシートで、
          // **transactionId ではない**。選び間違えると App Store Server API が
          // 引けなくなる。
          serverVerificationData: 'MIIT...base64-receipt...',
        ),
        '2000000912345678',
      );
    });

    test('microsoft は purchaseID のまま（サブスクは未対応だが軸は同じ）', () {
      expect(
        entitlementPurchaseIdFor(
          store: 'microsoft',
          purchaseId: 'ms-order-id',
          serverVerificationData: 'ms-token',
        ),
        'ms-order-id',
      );
    });

    // ⚠ 呼び出し側は「無ければ利用権を引けない」として成功に見せない
    // （`entitlement_missing_id`）。null と空文字を同じ扱いにする。
    test('⚠ google で token が空なら null（成功に見せない）', () {
      expect(
        entitlementPurchaseIdFor(
          store: 'google',
          purchaseId: 'GPA.3351-1234-5678-90123',
          serverVerificationData: '',
        ),
        isNull,
      );
      expect(
        entitlementPurchaseIdFor(
          store: 'google',
          purchaseId: 'GPA.3351-1234-5678-90123',
          serverVerificationData: null,
        ),
        isNull,
      );
    });

    // ⚠⚠ **orderId に倒れないことを明示的に固定する。**「token が無いなら
    // purchaseID で代用」は**元の不具合そのもの**なので、絶対に書かせない。
    test('🔴 google で token が無いときに purchaseID へ代用しない', () {
      final fallback = entitlementPurchaseIdFor(
        store: 'google',
        purchaseId: 'GPA.3351-1234-5678-90123',
        serverVerificationData: null,
      );
      expect(fallback, isNot('GPA.3351-1234-5678-90123'));
    });

    test('store が不明なら purchaseID（relay 側が受け取らないので実害は無い）', () {
      expect(
        entitlementPurchaseIdFor(
          store: null,
          purchaseId: 'x',
          serverVerificationData: 'y',
        ),
        'x',
      );
    });
  });

  // ⚠⚠ **軸が 2 箇所に戻らないことを機械で見る (#1220)。**別々に持っていたのが
  // 根本原因で、片方だけ直すと「store は google なのに Apple の値」に戻る。
  group('⚠ ストアの軸が 1 箇所に閉じている', () {
    const backendPath = 'lib/src/provider/supporter_purchase_backend.dart';

    test("前提: 走査が空振りしていない（backend に 'google' が実在する）", () {
      final backend = File(backendPath).readAsStringSync();

      expect(backend, contains("if (Platform.isAndroid) return 'google';"));
      expect(backend, contains("if (store == 'google') {"));
    });

    test('⚠⚠ 課金のストア名を決めているのは backend だけ', () {
      final offenders = <String>[];
      // ⚠ 列挙は [sourceFiles] に寄せる（#1168・`source_files_guard_test` が
      // `test` 配下の直書きを落とす）。
      for (final file in sourceFiles('lib/src')) {
        if (file.path.endsWith('supporter_purchase_backend.dart')) continue;
        // ⚠ TLD の一覧（`mastodon_tlds.dart`）は課金と無関係なので、
        // **`Platform` と同じ行にある場合だけ**を数える。
        final source = file.readAsStringSync();
        for (final line in source.split('\n')) {
          if (line.contains("'google'") && line.contains('Platform.is')) {
            offenders.add(file.path);
          }
        }
      }
      expect(offenders, isEmpty, reason: 'ストア名の判定は entitlementStoreName に寄せる');
    });
  });

  group('entitlementStoreName', () {
    // ⚠⚠ **`purchase_id` の選び方と同じ軸であることの固定 (#1220)。**別々に
    // 持っていたのが根本原因なので、同じファイルに在ることを検査で示す。
    test('この OS の store 名が、purchase_id の選び方と噛み合っている', () {
      final store = entitlementStoreName();

      if (Platform.isAndroid) {
        expect(store, 'google');
        expect(
          entitlementPurchaseIdFor(
            store: store,
            purchaseId: 'order',
            serverVerificationData: 'token',
          ),
          'token',
        );
      } else if (Platform.isIOS || Platform.isMacOS) {
        expect(store, 'apple');
        expect(
          entitlementPurchaseIdFor(
            store: store,
            purchaseId: 'txn',
            serverVerificationData: 'receipt',
          ),
          'txn',
        );
      } else if (Platform.isWindows) {
        expect(store, 'microsoft');
      } else {
        expect(store, isNull);
      }
    });
  });
}

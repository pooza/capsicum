import 'dart:io';

import 'package:in_app_purchase/in_app_purchase.dart';

import 'windows_store_backend.dart';

/// 投げ銭 SKU (#428 B-2: 3 階層・円基準 ¥100 / ¥500 / ¥800)。
///
/// 命名は将来のリレー利用権 SKU 統合を見据えた前方互換 (`supporter.*`)。
/// 実際の表示価格はストアの [ProductDetails.price] を使う（コード側に
/// 金額をハードコードしない）。リスト順が UI の表示順。MS Store の Product ID も
/// この SKU と完全一致で登録済み（#599 §E-5）。
const supporterTipProductIds = <String>[
  'supporter.tip.small', // ¥100 相当
  'supporter.tip.medium', // ¥500 相当
  'supporter.tip.big', // ¥800 相当
];

/// 購入ライフサイクルの 1 イベント（課金 backend 非依存）。
///
/// `in_app_purchase` の [PurchaseDetails] や Windows.Services.Store の購入結果を
/// この共通形へ正規化し、[SupporterPurchaseNotifier] は backend 実装を知らずに
/// 状態遷移だけを扱う（#599 plan §E-3）。
enum SupporterPurchaseEventStatus { pending, purchased, canceled, error }

class SupporterPurchaseEvent {
  final String productId;
  final SupporterPurchaseEventStatus status;

  /// error 時のみ。ストア固有のエラーコード（fingerprint 用・機密は載せない）。
  final String? errorCode;

  /// backend がストアトランザクションの完了処理を要するか
  /// （`completePurchase` / 消費報告）。purchased 以外は false。
  final bool needsCompletion;

  /// 完了処理に必要な backend 固有トークン。notifier は不透明に扱い
  /// [SupporterPurchaseBackend.complete] へ渡し戻す（in_app_purchase なら
  /// [PurchaseDetails]、Windows なら storeId）。
  final Object? completionToken;

  const SupporterPurchaseEvent({
    required this.productId,
    required this.status,
    this.errorCode,
    this.needsCompletion = false,
    this.completionToken,
  });
}

/// 投げ銭（消耗型 IAP）の課金 backend 抽象（#428 段 2 / #599 §E-3）。
///
/// 商品問い合わせ・購入・トランザクション完了をこの内側に閉じ、UI 契約
/// （[SupporterPurchaseState]）を変えずに OS ごとの課金実装を差し替える。
abstract class SupporterPurchaseBackend {
  /// この OS に課金経路が存在するか（存在しなければ notifier は何もしない）。
  bool get isSupported;

  /// 購入ライフサイクルのイベント列。stream 自体のエラーも上流へ伝播させ、
  /// notifier 側が `onError` で購入中フラグを戻せるようにする。
  Stream<SupporterPurchaseEvent> get purchaseEvents;

  /// ストアが利用可能か（非対応 / ストア不通 / 非 Store 版なら false）。
  Future<bool> isAvailable();

  /// 指定 SKU 群の商品情報を取得する（[supporterTipProductIds] 順は呼び出し側で
  /// 整える）。
  Future<List<ProductDetails>> queryProducts(Set<String> ids);

  /// 指定商品を消耗型として購入する。結果は [purchaseEvents] へ流す。
  Future<void> buy(ProductDetails product);

  /// ローカル永続化の成立後にストアトランザクションを確定させる
  /// （in_app_purchase は `completePurchase`、Windows は消費報告）。
  /// 永続化に失敗した購入では呼ばず、次回起動の再配信に委ねる。
  Future<void> complete(SupporterPurchaseEvent event);

  /// stream 購読等の後始末。
  void dispose();
}

/// OS に応じて課金 backend を選ぶ（#599 §E-3）。iOS / Android / macOS は
/// 公式 `in_app_purchase`、Windows は自前の [WindowsStoreBackend]。
SupporterPurchaseBackend createSupporterPurchaseBackend() {
  if (Platform.isWindows) {
    return WindowsStoreBackend();
  }
  if (Platform.isIOS || Platform.isAndroid || Platform.isMacOS) {
    return InAppPurchaseBackend();
  }
  return const _UnsupportedPurchaseBackend();
}

/// 公式 `in_app_purchase` ラッパー（iOS / Android / macOS）。
///
/// 従来 [SupporterPurchaseNotifier] が直接 `InAppPurchase.instance` を叩いていた
/// 経路を、意味を変えずにこの backend へ移した（出荷済みプラットフォームの
/// 挙動を保つ）。
class InAppPurchaseBackend implements SupporterPurchaseBackend {
  @override
  bool get isSupported =>
      Platform.isIOS || Platform.isAndroid || Platform.isMacOS;

  @override
  Stream<SupporterPurchaseEvent> get purchaseEvents =>
      // purchaseStream は List<PurchaseDetails> を流す。個々のイベントへ展開する。
      // expand は上流のエラーをそのまま透過するため、stream_error 経路
      // （notifier の onError）も従来どおり機能する。
      InAppPurchase.instance.purchaseStream.expand(
        (list) => list.map(_toEvent),
      );

  static SupporterPurchaseEvent _toEvent(PurchaseDetails p) {
    switch (p.status) {
      case PurchaseStatus.pending:
        return SupporterPurchaseEvent(
          productId: p.productID,
          status: SupporterPurchaseEventStatus.pending,
        );
      case PurchaseStatus.canceled:
        return SupporterPurchaseEvent(
          productId: p.productID,
          status: SupporterPurchaseEventStatus.canceled,
        );
      case PurchaseStatus.error:
        return SupporterPurchaseEvent(
          productId: p.productID,
          status: SupporterPurchaseEventStatus.error,
          errorCode: p.error?.code ?? 'unknown',
        );
      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        return SupporterPurchaseEvent(
          productId: p.productID,
          status: SupporterPurchaseEventStatus.purchased,
          needsCompletion: p.pendingCompletePurchase,
          completionToken: p,
        );
    }
  }

  @override
  Future<bool> isAvailable() => InAppPurchase.instance.isAvailable();

  @override
  Future<List<ProductDetails>> queryProducts(Set<String> ids) async {
    final response = await InAppPurchase.instance.queryProductDetails(ids);
    if (response.error != null) {
      throw response.error!;
    }
    return response.productDetails;
  }

  @override
  Future<void> buy(ProductDetails product) {
    // autoConsume=true: Android は即 consume して再投げ銭可能に。
    // iOS / macOS (StoreKit) は consumable のため指定は無視される。
    return InAppPurchase.instance.buyConsumable(
      purchaseParam: PurchaseParam(productDetails: product),
    );
  }

  @override
  Future<void> complete(SupporterPurchaseEvent event) async {
    final token = event.completionToken;
    if (token is PurchaseDetails && token.pendingCompletePurchase) {
      await InAppPurchase.instance.completePurchase(token);
    }
  }

  @override
  void dispose() {}
}

/// 課金経路が無い OS（Linux / 非 Store Windows は別途 backend で扱う）用の no-op。
class _UnsupportedPurchaseBackend implements SupporterPurchaseBackend {
  const _UnsupportedPurchaseBackend();

  @override
  bool get isSupported => false;

  @override
  Stream<SupporterPurchaseEvent> get purchaseEvents => const Stream.empty();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<List<ProductDetails>> queryProducts(Set<String> ids) async => const [];

  @override
  Future<void> buy(ProductDetails product) async {}

  @override
  Future<void> complete(SupporterPurchaseEvent event) async {}

  @override
  void dispose() {}
}

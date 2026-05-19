import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../service/exception_scrub.dart';
import 'supporter_status_provider.dart';

/// 投げ銭 SKU (#428 B-2: 3 階層・円基準 ¥150 / ¥500 / ¥800)。
///
/// 命名は将来のリレー利用権 SKU 統合を見据えた前方互換 (`supporter.*`)。
/// 実際の表示価格はストアの [ProductDetails.price] を使う（コード側に
/// 金額をハードコードしない）。リスト順が UI の表示順。
const supporterTipProductIds = <String>[
  'supporter.tip.small', // ¥150 相当
  'supporter.tip.medium', // ¥500 相当
  'supporter.tip.large', // ¥800 相当
];

/// 購入導線を出すプラットフォーム (#428 D-1)。iOS / Android のみ。
/// macOS は後日、Linux / Windows はストア IAP 不在。`in_app_purchase` は
/// 非対応 OS で `InAppPurchase.instance` 取得時に落ちるため、触る前に判定する。
bool get supporterPurchaseSupported => Platform.isIOS || Platform.isAndroid;

enum SupporterPurchaseOutcomeKind { success, canceled, error }

/// 直近の購入試行結果。UI（段 3）がスナックバー等で提示する。
class SupporterPurchaseOutcome {
  final SupporterPurchaseOutcomeKind kind;

  /// error 時のみ。スクラブ済みの短い説明（生レスポンスは載せない）。
  final String? message;

  const SupporterPurchaseOutcome(this.kind, {this.message});
}

/// `lastOutcome` を「保持／クリア／差し替え」の三状態で扱う sentinel
/// （[DriveState.loadMoreError] と同じ手法）。
const Object _keepOutcome = Object();

class SupporterPurchaseState {
  /// ストア課金が利用可能か（非対応 OS / ストア不通なら false）。
  final bool isAvailable;

  /// 商品情報の問い合わせ中。
  final bool isLoadingProducts;

  /// ストアから取得済みの商品（[supporterTipProductIds] 順）。
  final List<ProductDetails> products;

  /// 購入処理中（ボタン二度押し抑止に使う）。
  final bool purchaseInProgress;

  /// 直近の購入試行結果。未試行なら null。
  final SupporterPurchaseOutcome? lastOutcome;

  const SupporterPurchaseState({
    this.isAvailable = false,
    this.isLoadingProducts = false,
    this.products = const [],
    this.purchaseInProgress = false,
    this.lastOutcome,
  });

  SupporterPurchaseState copyWith({
    bool? isAvailable,
    bool? isLoadingProducts,
    List<ProductDetails>? products,
    bool? purchaseInProgress,
    Object? lastOutcome = _keepOutcome,
  }) => SupporterPurchaseState(
    isAvailable: isAvailable ?? this.isAvailable,
    isLoadingProducts: isLoadingProducts ?? this.isLoadingProducts,
    products: products ?? this.products,
    purchaseInProgress: purchaseInProgress ?? this.purchaseInProgress,
    lastOutcome: identical(lastOutcome, _keepOutcome)
        ? this.lastOutcome
        : lastOutcome as SupporterPurchaseOutcome?,
  );
}

/// 消耗型 IAP の購入フロー (#428 段 2)。
///
/// 商品タイプ（消耗型）・課金プラグインをこの内側に閉じ、成功時は
/// [supporterStatusProvider] の `markTipped` を呼ぶだけ。UI はバッジを
/// [isSupporterProvider] で見るので、購入手段の詳細を知らない。
/// 購入は画面を閉じた後に確定し得るためアプリ寿命で購読する
/// （autoDispose しない）。
class SupporterPurchaseNotifier extends Notifier<SupporterPurchaseState> {
  StreamSubscription<List<PurchaseDetails>>? _sub;

  @override
  SupporterPurchaseState build() {
    if (!supporterPurchaseSupported) {
      return const SupporterPurchaseState();
    }
    _sub = InAppPurchase.instance.purchaseStream.listen(
      _onPurchaseUpdates,
      onError: (Object e, StackTrace st) {
        Sentry.captureException(
          scrubException(e),
          stackTrace: st,
          withScope: (scope) {
            scope.setTag('supporter.purchase', 'stream_error');
            scope.fingerprint = [
              'supporter.purchase.stream',
              e.runtimeType.toString(),
            ];
          },
        );
      },
    );
    ref.onDispose(() => _sub?.cancel());
    // 商品問い合わせを起動（結果は state に反映）。
    scheduleMicrotask(loadProducts);
    return const SupporterPurchaseState(isLoadingProducts: true);
  }

  /// ストアから商品情報を取得する。画面再表示時に UI から再呼び出し可。
  Future<void> loadProducts() async {
    if (!supporterPurchaseSupported) return;
    state = state.copyWith(isLoadingProducts: true);
    try {
      final available = await InAppPurchase.instance.isAvailable();
      if (!available) {
        state = state.copyWith(isAvailable: false, isLoadingProducts: false);
        return;
      }
      final response = await InAppPurchase.instance.queryProductDetails(
        supporterTipProductIds.toSet(),
      );
      if (response.error != null) {
        throw response.error!;
      }
      final byId = {for (final p in response.productDetails) p.id: p};
      // 定義順（金額昇順）に整列。ストアに存在しない ID は黙って除外する。
      final ordered = [
        for (final id in supporterTipProductIds)
          if (byId[id] != null) byId[id]!,
      ];
      state = state.copyWith(
        isAvailable: true,
        isLoadingProducts: false,
        products: ordered,
      );
    } catch (e, st) {
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('supporter.purchase', 'load_products_failed');
          scope.fingerprint = [
            'supporter.purchase.load_products',
            e.runtimeType.toString(),
          ];
        },
      );
      state = state.copyWith(isAvailable: false, isLoadingProducts: false);
    }
  }

  /// 指定 SKU を消耗型として購入する。結果は購入ストリーム経由で
  /// [state] / [SupporterStatusNotifier] に反映される。
  Future<void> buy(ProductDetails product) async {
    if (!supporterPurchaseSupported || state.purchaseInProgress) return;
    state = state.copyWith(purchaseInProgress: true, lastOutcome: null);
    try {
      // autoConsume=true: Android は即 consume して再投げ銭可能に。
      // iOS は consumable のため指定は無視される。
      await InAppPurchase.instance.buyConsumable(
        purchaseParam: PurchaseParam(productDetails: product),
      );
    } catch (e, st) {
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('supporter.purchase', 'buy_failed');
          scope.fingerprint = [
            'supporter.purchase.buy',
            e.runtimeType.toString(),
          ];
        },
      );
      state = state.copyWith(
        purchaseInProgress: false,
        lastOutcome: const SupporterPurchaseOutcome(
          SupporterPurchaseOutcomeKind.error,
        ),
      );
    }
  }

  Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      switch (p.status) {
        case PurchaseStatus.pending:
          state = state.copyWith(purchaseInProgress: true);
          break;
        case PurchaseStatus.canceled:
          // ユーザー操作。例外ではないので breadcrumb のみ。
          Sentry.addBreadcrumb(
            Breadcrumb(
              category: 'supporter.purchase',
              level: SentryLevel.info,
              message: 'canceled',
            ),
          );
          state = state.copyWith(
            purchaseInProgress: false,
            lastOutcome: const SupporterPurchaseOutcome(
              SupporterPurchaseOutcomeKind.canceled,
            ),
          );
          break;
        case PurchaseStatus.error:
          Sentry.captureException(
            scrubException(p.error ?? Exception('purchase error')),
            withScope: (scope) {
              scope.setTag('supporter.purchase', 'purchase_error');
              scope.fingerprint = [
                'supporter.purchase.error',
                (p.error?.code ?? 'unknown'),
              ];
            },
          );
          state = state.copyWith(
            purchaseInProgress: false,
            lastOutcome: const SupporterPurchaseOutcome(
              SupporterPurchaseOutcomeKind.error,
            ),
          );
          break;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // 消耗型につきレシート検証は最小（ストアを信頼）。サーバー側
          // 保持に移行した時点で検証経路を抽象層内に追加する（B-4）。
          await ref
              .read(supporterStatusProvider.notifier)
              .markTipped(sku: p.productID);
          state = state.copyWith(
            purchaseInProgress: false,
            lastOutcome: const SupporterPurchaseOutcome(
              SupporterPurchaseOutcomeKind.success,
            ),
          );
          break;
      }
      // ストアトランザクションを完了させる（未完了だと再配信され続ける）。
      if (p.pendingCompletePurchase) {
        await InAppPurchase.instance.completePurchase(p);
      }
    }
  }
}

final supporterPurchaseProvider =
    NotifierProvider<SupporterPurchaseNotifier, SupporterPurchaseState>(
      SupporterPurchaseNotifier.new,
    );

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../util/exception_scrub.dart';
import 'supporter_purchase_backend.dart';
import 'supporter_status_provider.dart';

export 'supporter_purchase_backend.dart' show supporterTipProductIds;

/// 購入導線を出すプラットフォーム (#428 D-1)。iOS / Android に加え、#598 で
/// macOS (Mac App Store IAP) を解放。iOS / macOS は Universal Purchase
/// (同一 App レコード) のため ASC の消耗型 3 商品をそのまま共有し、
/// `in_app_purchase` も macOS を in_app_purchase_storekit で公式サポートする。
/// Windows は #599 でストア IAP（Microsoft Store）を解放するが、購入は
/// **Store からインストールされたコピーでのみ**成立するため、入口の可否は
/// 実行時に商品問い合わせが通るか（[SupporterPurchaseState.isAvailable]）で
/// 決める。この getter はコンパイル時に backend の有無だけを表す。Linux は
/// ストア IAP 不在。
bool get supporterPurchaseSupported =>
    Platform.isIOS || Platform.isAndroid || Platform.isMacOS;

/// この OS に投げ銭の課金 backend が存在するか（サポート画面のハード無効表示を
/// 出すかの判定）。Windows は Store 版のみ購入成立だが backend 自体は存在する
/// ため true にし、実際に購入できるか（Store 版か・商品を取得できたか）は
/// [SupporterPurchaseState.isAvailable] で別途出し分ける (#599 §E-2)。
bool get supporterPurchaseHasBackend =>
    supporterPurchaseSupported || Platform.isWindows;

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
  late final SupporterPurchaseBackend _backend;
  StreamSubscription<SupporterPurchaseEvent>? _sub;

  @override
  SupporterPurchaseState build() {
    // 課金経路を OS ごとの backend に閉じる (#599 §E-3)。iOS / Android / macOS は
    // in_app_purchase、Windows は Windows.Services.Store の自前 channel。
    _backend = createSupporterPurchaseBackend();
    if (!_backend.isSupported) {
      return const SupporterPurchaseState();
    }
    _sub = _backend.purchaseEvents.listen(
      _onEvent,
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
        // 購入ストリーム自体が崩壊した場合も purchaseInProgress を戻す。
        // buy() 後にここへ来ると、各購入ステータス分岐を一切経由しないため
        // フラグがリセットされず投げ銭ボタンが固着する。
        state = state.copyWith(
          purchaseInProgress: false,
          lastOutcome: const SupporterPurchaseOutcome(
            SupporterPurchaseOutcomeKind.error,
          ),
        );
      },
    );
    ref.onDispose(() {
      _sub?.cancel();
      _backend.dispose();
    });
    // 商品問い合わせを起動（結果は state に反映）。
    scheduleMicrotask(loadProducts);
    return const SupporterPurchaseState(isLoadingProducts: true);
  }

  /// ストアから商品情報を取得する。画面再表示時に UI から再呼び出し可。
  Future<void> loadProducts() async {
    if (!_backend.isSupported) return;
    state = state.copyWith(isLoadingProducts: true);
    try {
      final available = await _backend.isAvailable();
      if (!available) {
        state = state.copyWith(isAvailable: false, isLoadingProducts: false);
        return;
      }
      final products = await _backend.queryProducts(
        supporterTipProductIds.toSet(),
      );
      final byId = {for (final p in products) p.id: p};
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

  /// 指定 SKU を消耗型として購入する。結果は購入イベント経由で
  /// [state] / [SupporterStatusNotifier] に反映される。
  Future<void> buy(ProductDetails product) async {
    if (!_backend.isSupported || state.purchaseInProgress) return;
    state = state.copyWith(purchaseInProgress: true, lastOutcome: null);
    try {
      await _backend.buy(product);
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

  /// backend が正規化した購入イベント 1 件を状態遷移へ落とす。
  ///
  /// in_app_purchase の `List<PurchaseDetails>` 単位の処理を、backend 抽象
  /// （[SupporterPurchaseEvent]）の 1 件単位に置き換えたもの。トランザクション
  /// 完了（in_app_purchase の completePurchase / Windows の消費報告）は
  /// [SupporterPurchaseBackend.complete] に委ね、ローカル永続化が成立した
  /// 購入だけを確定させる。
  Future<void> _onEvent(SupporterPurchaseEvent event) async {
    switch (event.status) {
      case SupporterPurchaseEventStatus.pending:
        state = state.copyWith(purchaseInProgress: true);
        return;
      case SupporterPurchaseEventStatus.canceled:
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
        return;
      case SupporterPurchaseEventStatus.error:
        Sentry.captureException(
          scrubException(Exception('purchase error')),
          withScope: (scope) {
            scope.setTag('supporter.purchase', 'purchase_error');
            scope.fingerprint = [
              'supporter.purchase.error',
              event.errorCode ?? 'unknown',
            ];
          },
        );
        state = state.copyWith(
          purchaseInProgress: false,
          lastOutcome: const SupporterPurchaseOutcome(
            SupporterPurchaseOutcomeKind.error,
          ),
        );
        return;
      case SupporterPurchaseEventStatus.purchased:
        // 消耗型につきレシート検証は最小（ストアを信頼）。サーバー側
        // 保持に移行した時点で検証経路を抽象層内に追加する（B-4）。
        var persisted = true;
        try {
          await ref
              .read(supporterStatusProvider.notifier)
              .markTipped(sku: event.productId);
          state = state.copyWith(
            purchaseInProgress: false,
            lastOutcome: const SupporterPurchaseOutcome(
              SupporterPurchaseOutcomeKind.success,
            ),
          );
        } catch (e, st) {
          // 課金はストア側で成立済みだが、ローカル記録の永続化に失敗。
          // purchaseInProgress を必ず戻してボタン固着を防ぐ（#298 同型）。
          // complete を呼ばないことで、in_app_purchase は次回起動の再配信、
          // Windows は次回購入時の AlreadyPurchased で markTipped を再試行する。
          persisted = false;
          Sentry.captureException(
            scrubException(e),
            stackTrace: st,
            withScope: (scope) {
              scope.setTag('supporter.purchase', 'mark_tipped_failed');
              scope.fingerprint = [
                'supporter.purchase.mark_tipped',
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
        // ストアトランザクションを確定させる（未確定だと再配信され続ける /
        // 消耗型残高が残る）。永続化に失敗した購入はあえて確定させず再試行に委ねる。
        if (persisted && event.needsCompletion) {
          try {
            await _backend.complete(event);
          } catch (e, st) {
            // 確定（completePurchase / 消費報告）に失敗。ローカルのバッジは
            // 成立済み。未確定トランザクションは再配信 / AlreadyPurchased で
            // 拾い直せるため、観測だけして本筋は止めない。
            Sentry.captureException(
              scrubException(e),
              stackTrace: st,
              withScope: (scope) {
                scope.setTag('supporter.purchase', 'complete_failed');
                scope.fingerprint = [
                  'supporter.purchase.complete',
                  e.runtimeType.toString(),
                ];
              },
            );
          }
        }
        return;
    }
  }
}

final supporterPurchaseProvider =
    NotifierProvider<SupporterPurchaseNotifier, SupporterPurchaseState>(
      SupporterPurchaseNotifier.new,
    );

/// 設定に投げ銭エントリ（購入導線）を出すか (#428 D-1 / #599 §E-2)。
///
/// iOS / Android / macOS は常に出す（[supporterPurchaseSupported]）。Windows は
/// 購入が **Microsoft Store からインストールされたコピーでのみ**成立するため、
/// 商品問い合わせが通って利用可能になった（= Store 版）ときだけ出す。直配版
/// （自己署名 MSIX）や非対応 OS では隠す（§E-2(a)・空振りの入口を出さない）。
/// mobile では `supporterPurchaseSupported` で短絡し、購入 provider を余計に
/// 起動しない。
final supporterEntryVisibleProvider = Provider<bool>((ref) {
  if (supporterPurchaseSupported) return true;
  if (Platform.isWindows) {
    return ref.watch(supporterPurchaseProvider.select((s) => s.isAvailable));
  }
  return false;
});

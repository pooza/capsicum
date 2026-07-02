import 'dart:async';

import 'package:flutter/services.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'supporter_purchase_backend.dart';

/// Windows.Services.Store を叩く投げ銭 backend（#599 §E-1/§E-3）。
///
/// runner の 'capsicum/store_iap' チャンネル（[windows_store_iap.cpp]）を薄く
/// ラップし、[SupporterPurchaseBackend] 契約に合わせる。購入は request/response
/// のため、結果を [purchaseEvents] へ流して in_app_purchase の stream 型に揃える。
class WindowsStoreBackend implements SupporterPurchaseBackend {
  static const _channel = MethodChannel('capsicum/store_iap');

  final StreamController<SupporterPurchaseEvent> _events =
      StreamController<SupporterPurchaseEvent>.broadcast();

  /// productId(SKU) → storeId。購入 / 消費報告は StoreId 指定のため、直近の
  /// 商品問い合わせ結果から引く。
  final Map<String, String> _storeIds = {};

  /// 直近の商品問い合わせ結果（[isAvailable] が probe し [queryProducts] が再利用）。
  bool? _lastIsStoreVersion;
  List<ProductDetails> _lastProducts = const [];

  @override
  bool get isSupported => true;

  @override
  Stream<SupporterPurchaseEvent> get purchaseEvents => _events.stream;

  @override
  Future<bool> isAvailable() async {
    await _probe();
    return _lastIsStoreVersion ?? false;
  }

  @override
  Future<List<ProductDetails>> queryProducts(Set<String> ids) async {
    // loadProducts は isAvailable() → queryProducts() の順で呼ぶため、直前の
    // probe 結果を再利用してチャンネル往復を 1 回に抑える。単独呼び出しに備え
    // 未 probe なら取得する。
    if (_lastIsStoreVersion == null) {
      await _probe(ids: ids);
    }
    return _lastProducts;
  }

  /// チャンネルへ商品問い合わせし、Store 版判定・商品・storeId マップを更新する。
  Future<void> _probe({Set<String>? ids}) async {
    final wanted = ids ?? supporterTipProductIds.toSet();
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'queryProducts',
      wanted.toList(),
    );
    _storeIds.clear();
    if (result == null) {
      _lastIsStoreVersion = false;
      _lastProducts = const [];
      return;
    }
    _lastIsStoreVersion = result['isStoreVersion'] == true;
    final rawProducts = (result['products'] as List?) ?? const [];
    final byId = <String, ProductDetails>{};
    for (final raw in rawProducts) {
      final map = (raw as Map).cast<String, dynamic>();
      final productId = map['productId'] as String? ?? '';
      final storeId = map['storeId'] as String? ?? '';
      if (productId.isEmpty || storeId.isEmpty) continue;
      _storeIds[productId] = storeId;
      // Windows.Services.Store は表示価格のみを返すため、rawPrice / currencyCode
      // は 0 / 空で合成する（UI は整形済み [ProductDetails.price] だけを見る）。
      byId[productId] = ProductDetails(
        id: productId,
        title: map['title'] as String? ?? '',
        description: map['description'] as String? ?? '',
        price: map['formattedPrice'] as String? ?? '',
        rawPrice: 0.0,
        currencyCode: '',
      );
    }
    // 定義順（金額昇順）に整列。存在しない ID は黙って除外（in_app_purchase 経路と同じ）。
    _lastProducts = [
      for (final id in supporterTipProductIds)
        if (byId[id] != null) byId[id]!,
    ];
  }

  @override
  Future<void> buy(ProductDetails product) async {
    final storeId = _storeIds[product.id];
    if (storeId == null) {
      _events.add(
        SupporterPurchaseEvent(
          productId: product.id,
          status: SupporterPurchaseEventStatus.error,
          errorCode: 'no_store_id',
        ),
      );
      return;
    }
    final result = await _channel.invokeMapMethod<String, dynamic>('purchase', {
      'storeId': storeId,
    });
    // StorePurchaseStatus: Succeeded=0 / AlreadyPurchased=1 / NotPurchased=2 /
    // NetworkError=3 / ServerError=4。
    final status = (result?['status'] as int?) ?? 3;
    switch (status) {
      case 0: // Succeeded
      case 1: // AlreadyPurchased（未消費の消耗型が残存）→ 付与して消費報告する。
        _events.add(
          SupporterPurchaseEvent(
            productId: product.id,
            status: SupporterPurchaseEventStatus.purchased,
            needsCompletion: true,
            completionToken: storeId,
          ),
        );
        break;
      case 2: // NotPurchased（ユーザーがダイアログをキャンセル）。
        _events.add(
          SupporterPurchaseEvent(
            productId: product.id,
            status: SupporterPurchaseEventStatus.canceled,
          ),
        );
        break;
      default: // NetworkError / ServerError。
        _events.add(
          SupporterPurchaseEvent(
            productId: product.id,
            status: SupporterPurchaseEventStatus.error,
            errorCode: status == 4 ? 'server' : 'network',
          ),
        );
        break;
    }
  }

  @override
  Future<void> complete(SupporterPurchaseEvent event) async {
    // 消耗型の消費報告（plan §E-4）。ローカル永続化が成立した後に呼ばれる。
    final storeId = event.completionToken;
    if (storeId is! String || storeId.isEmpty) return;
    // 報告失敗はストア側に未消費として残るが、次回購入時に AlreadyPurchased で
    // 拾い直して再報告できるため、ここでは best-effort に留める（呼び出し元の
    // notifier が try/catch で観測する）。
    await _channel.invokeMapMethod<String, dynamic>('reportFulfillment', {
      'storeId': storeId,
    });
  }

  @override
  void dispose() {
    _events.close();
  }
}

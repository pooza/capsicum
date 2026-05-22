import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../constants.dart';
import '../../../provider/supporter_purchase_provider.dart';
import '../../../provider/supporter_status_provider.dart';
import '../../../url_helper.dart';

/// capsicum サポーター（投げ銭）画面 (#428 段 3)。
///
/// B 確定方針:
/// - 単発（消耗型）。サブスクではない（解約導線・継続課金なし）
/// - 機能差別化なし。投げ銭しても全機能は誰でも使えるまま
/// - 一度でも投げ銭すれば生涯サポーターバッジ（B-3）
///
/// 購入導線は iOS / Android のみ（D-1）。非対応 OS では説明のみ表示する。
class SupporterScreen extends ConsumerWidget {
  const SupporterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 購入結果をスナックバーで提示（成功 / キャンセル / 失敗）。
    ref.listen<SupporterPurchaseState>(supporterPurchaseProvider, (prev, next) {
      final outcome = next.lastOutcome;
      if (outcome == null || outcome == prev?.lastOutcome) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      final text = switch (outcome.kind) {
        SupporterPurchaseOutcomeKind.success => 'ありがとうございます！サポーターになりました。',
        SupporterPurchaseOutcomeKind.canceled => '購入をキャンセルしました。',
        SupporterPurchaseOutcomeKind.error => '購入を完了できませんでした。時間をおいて再度お試しください。',
      };
      messenger.showSnackBar(SnackBar(content: Text(text)));
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('capsicum をサポート'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'capsicum は投げ銭で開発と通知リレーの運用を支援できます。'
              'これは任意の応援です。投げ銭をしてもしなくても、'
              'すべての機能はこれまでどおり誰でも利用できます。',
              style: TextStyle(fontSize: 13),
            ),
          ),
          if (ref.watch(isSupporterProvider))
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'いつもありがとうございます。あなたはサポーターです。'
                '追加で投げ銭することもできます。',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),
          const Divider(),
          ..._buildPurchaseSection(context, ref),
          const Divider(),
          // 特定商取引法に基づく表記 (#428 C-3)。日本の消費者向け IAP の
          // 表示義務。capsicum-site 上の法人名義ページ (有限会社ビーショック)
          // へリンクする。
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: const Text('特定商取引法に基づく表記'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => launchUrlSafely(AppConstants.tokushohoUrl),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildPurchaseSection(BuildContext context, WidgetRef ref) {
    if (!supporterPurchaseSupported) {
      return const [
        Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'このプラットフォームではアプリ内での投げ銭に対応していません。'
            'iOS / Android 版からご利用ください。',
            style: TextStyle(fontSize: 13),
          ),
        ),
      ];
    }

    final state = ref.watch(supporterPurchaseProvider);

    if (state.isLoadingProducts) {
      return const [
        Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    if (!state.isAvailable || state.products.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            'ただいま投げ銭をご利用いただけません。'
            'ストアに接続できないか、商品情報を取得できませんでした。',
            style: TextStyle(fontSize: 13),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton(
            onPressed: () =>
                ref.read(supporterPurchaseProvider.notifier).loadProducts(),
            child: const Text('再読み込み'),
          ),
        ),
      ];
    }

    return [
      for (final product in state.products)
        ListTile(
          leading: const Icon(Icons.favorite, color: Colors.pink),
          title: Text(product.title),
          subtitle: Text(product.description),
          trailing: FilledButton(
            onPressed: state.purchaseInProgress
                ? null
                : () =>
                      ref.read(supporterPurchaseProvider.notifier).buy(product),
            child: Text(product.price),
          ),
        ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Text(
          '投げ銭は単発のお支払いです（継続課金ではありません）。'
          '一度でも投げ銭すると、サポーターバッジが恒久的に付与されます。',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ),
    ];
  }
}

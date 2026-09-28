import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../constants.dart';
import '../../../provider/supporter_purchase_provider.dart';
import '../../../provider/supporter_status_provider.dart';
import '../../util/launch_url_toast.dart';

/// capsicum サポーター（投げ銭）画面 (#428 段 3)。
///
/// 投げ銭（#428 B 確定方針）:
/// - 単発（消耗型）。⚠ **投げ銭そのものはサブスクではない**（解約導線なし）
/// - 機能差別化なし。投げ銭しても全機能は誰でも使えるまま
/// - 一度でも投げ銭すれば生涯サポーターバッジ（B-3）
///
/// ⚠⚠ **この画面には利用権サブスクも並ぶ (#597 / #1122)。**投げ銭とは別の商品で、
/// **置き換えではなく追加**（設計書 決定済み事項 3）。⚠ **2 つを混ぜないこと** ——
/// 投げ銭は「任意の応援」、利用権は「非プリセットサーバーでのプッシュ通知」という
/// 機能に対する対価で、⚠ **成功時の文言も解約の扱いも違う。**
///
/// 購入導線は iOS / Android / macOS（D-1）。非対応 OS では説明のみ表示する。
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
      // ⚠⚠ **投げ銭とサブスクで文言を分ける (#1122)。**成功の意味が違うので、
      // 同じ文面だと**買ったものを取り違えて伝える**。
      final text = switch ((outcome.kind, outcome.isSubscription)) {
        (SupporterPurchaseOutcomeKind.success, true) =>
          'ありがとうございます！リレーの利用権が有効になりました。',
        (SupporterPurchaseOutcomeKind.success, false) =>
          'ありがとうございます！サポーターになりました。',
        (SupporterPurchaseOutcomeKind.canceled, _) => '購入をキャンセルしました。',
        // ⚠ サブスクは購入が成立していても利用権の発行で落ちることがある
        // （relay へ届かない等）。⚠⚠ **「購入できなかった」と言い切らない。**
        (SupporterPurchaseOutcomeKind.error, true) =>
          '利用権を有効にできませんでした。時間をおいてアプリを開き直してください。',
        (SupporterPurchaseOutcomeKind.error, false) =>
          '購入を完了できませんでした。時間をおいて再度お試しください。',
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
            // ⚠ **この画面で唯一 fire-and-forget だった (#976)。**同じ画面の
            // Patreon / Liberapay は #924 で失敗時 SnackBar へ移したのに、
            // ここだけ直呼びのままで、**IAP 画面で法定表示に到達できない失敗が
            // 無音**になっていた。
            onTap: () => _openSupportLink(context, AppConstants.tokushohoUrl),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildPurchaseSection(BuildContext context, WidgetRef ref) {
    if (!supporterPurchaseHasBackend) {
      // 課金 backend が無い OS（Linux）は Web の支援先へ案内する (#893)。
      // ストア版（App Store / Google Play / Microsoft Store）では出さない
      // ＝各ストアがアプリ内から外部決済・寄付へ誘導することを制限しており、
      // IAP と並べるとリジェクト要因になりうるため。Windows は backend が
      // あるので、購入可否は下の isAvailable / products で出し分ける。
      return [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            'このプラットフォームにはアプリ内の投げ銭がないため、'
            'Web のサービスからご支援いただけます。',
            style: TextStyle(fontSize: 13),
          ),
        ),
        ListTile(
          leading: Image.asset(
            AppConstants.supporterIconAsset,
            width: 30,
            height: 30,
          ),
          title: const Text('Patreon'),
          subtitle: const Text('ブラウザで開きます'),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => _openSupportLink(context, AppConstants.patreonUrl),
        ),
        ListTile(
          leading: Image.asset(
            AppConstants.supporterIconAsset,
            width: 30,
            height: 30,
          ),
          title: const Text('Liberapay'),
          subtitle: const Text('ブラウザで開きます'),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => _openSupportLink(context, AppConstants.liberapayUrl),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Text(
            'Web でのご支援はアプリのアカウントと結び付かないため、'
            'サポーターバッジは付きません。応援としてありがたく受け取ります。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
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
      ..._subscriptionSection(ref, state),
      for (final product in state.products)
        ListTile(
          leading: Image.asset(
            AppConstants.supporterIconAsset,
            width: 30,
            height: 30,
          ),
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

  /// 有償リレーの利用権サブスク (#597 / #1122)。
  ///
  /// ⚠⚠ **投げ銭を置き換えない。**設計書 決定済み事項 3 のとおり「既存の投げ銭は
  /// 残したまま、サブスクを**追加**する」。並べる順は**利用権が先**（機能に対する
  /// 対価なので、任意の応援より先に説明が要る）。
  ///
  /// ⚠ **商品が取れなければ丸ごと出さない** —— ストア未登録・審査前・
  /// サブスクを扱えない OS。**押しても買えない入口を作らない。**
  List<Widget> _subscriptionSection(
    WidgetRef ref,
    SupporterPurchaseState state,
  ) {
    final product = state.subscription;
    if (product == null) return const [];

    return [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(
          'リレーの利用権',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text(
          // ⚠ **便益を正確に書く。**プリセットサーバーの利用者は元から無償で
          // 使えるので、「これを買わないと通知が来ない」ではない。
          'capsicum の運営元が用意したサーバー以外でも、プッシュ通知を'
          '受け取れるようになります。運営元のサーバーをお使いの方は、'
          '購入しなくてもこれまでどおり通知を受け取れます。',
          style: TextStyle(fontSize: 13),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.notifications_active_outlined),
        title: Text(product.title),
        subtitle: Text(product.description),
        trailing: state.hasEntitlement
            // ⚠ **持っている人にボタンを出さない。**1 つの購入を複数端末で
            // 使えるので、押させると二重購入になる。
            ? const Text('利用中')
            : FilledButton(
                onPressed: state.purchaseInProgress
                    ? null
                    : () => ref
                          .read(supporterPurchaseProvider.notifier)
                          .subscribe(product),
                child: Text(product.price),
              ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Text(
          // ⚠ 解約の窓口はストア。⚠⚠ **アプリ内に解約導線を作らない**
          // （ストアの規約上、アプリから直接は解約できない）。
          '毎月の自動更新です。解約はご利用のストア（App Store / Google Play）から'
          '行えます。',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ),
      const Divider(height: 1),
    ];
  }

  /// Web の支援先を外部ブラウザで開く。起動に失敗したら黙って捨てず SnackBar で
  /// 知らせる (#924)。
  ///
  /// ⚠ **失敗の扱いは [launchUrlOrToast] に寄せた (#976)。**同じ SnackBar
  /// ブロックが 4 箇所に写っていたうえ、ここだけ `launchUrl` の
  /// `PlatformException`（ハンドラ不在の端末）を受けていなかった。
  Future<void> _openSupportLink(BuildContext context, Uri url) =>
      launchUrlOrToast(context, url);
}

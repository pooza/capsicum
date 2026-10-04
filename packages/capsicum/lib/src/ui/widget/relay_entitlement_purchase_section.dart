import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../provider/entitlement_status_provider.dart';
import '../../provider/supporter_purchase_provider.dart';
import '../util/launch_url_toast.dart';

/// 有償リレーの利用権の購入導線 (#597 / #1122 / #1217)。
///
/// ⚠⚠ **サポーター画面とプッシュ通知設定画面で共有する。**#1217 の案 C。購入の
/// 実装（[supporterPurchaseProvider]）は 1 本のままなので、**「利用中」表示＝
/// 二重購入の防止も、商品が取れないときに丸ごと消えることも、両画面で同じに効く。**
///
/// ⚠ **採らなかった形**: プッシュ通知画面側で購入を作り直す —— 法定表記・解約の
/// 説明・二重購入の防止を 2 箇所に複写することになる。
///
/// ⚠⚠ **このウィジェットを組む前に、呼び出し側が「出すべきか」を判定すること。**
/// ここで [supporterPurchaseProvider] を `watch` するので、**組んだ時点でストアへの
/// 商品問い合わせが走る**（provider の build が `loadProducts` を起動する）。
/// プッシュ通知設定画面は [showRelayPurchaseEntry] で手前に門を置いている。
class RelayEntitlementPurchaseSection extends ConsumerWidget {
  /// 便益の説明を添えるか。
  ///
  /// ⚠ **プッシュ通知設定画面では false。**あちらは利用権の節（#1123）が同じ
  /// ことを状態別の文面で既に言っているので、**足すと同じ説明が 2 回出る。**
  final bool showBenefit;

  /// 特定商取引法に基づく表記を節に同梱するか。
  ///
  /// ⚠⚠ **購入ボタンのある画面に要る**（[`supporter-subscription-plan.md`]
  /// C-3 の「アプリ内購入導線からリンク参照」）。⚠ **サポーター画面では false** ——
  /// あちらは画面レベルに 1 行あり、**投げ銭（消耗型）と共通**なので、節へ寄せると
  /// **サブスク商品が取れない回に投げ銭の法定表記ごと消える。**
  final bool showLegalNotice;

  const RelayEntitlementPurchaseSection({
    super.key,
    required this.showBenefit,
    required this.showLegalNotice,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(supporterPurchaseProvider);
    final product = state.subscription;
    // ⚠ **商品が取れなければ丸ごと出さない** —— ストア未登録・審査前・
    // サブスクを扱えない OS。**押しても買えない入口を作らない。**
    if (product == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showBenefit)
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
        if (showLegalNotice)
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: const Text('特定商取引法に基づく表記'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            // ⚠ 失敗を黙って捨てない (#976)。
            onTap: () => launchUrlOrToast(context, AppConstants.tokushohoUrl),
          ),
      ],
    );
  }
}

/// 購入結果の文面 (#1122 / #1217)。
///
/// ⚠⚠ **2 画面で同じ文面を使うので 1 本にしてある。**購入の入口が増えた
/// (#1217) ことで、⚠ **写すと「買ったものを取り違えて伝える」分岐が 2 箇所に
/// 散る**（投げ銭とサブスクで成功の意味が違う）。
///
/// ⚠ **スナックバーの `ref.listen` は画面側に置く。**このウィジェットは購入が
/// 成立すると（利用権が有効になって）**消える側**なので、ここで待ち受けると
/// **結果を出す前に unmount されうる。**
String supporterPurchaseOutcomeMessage(SupporterPurchaseOutcome outcome) =>
    switch ((outcome.kind, outcome.isSubscription)) {
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

/// プッシュ通知設定画面に購入の入口を出すか (#1217)。
///
/// 判断材料が真偽値と enum だけなので、画面から切り出してテスト可能にしてある
/// （[showEntitlementSection] と同じ流儀）。
///
/// ⚠⚠ **プリセットのアカウントが 1 つでもあれば出さない。**#1123 の完了条件 3
/// 「何も表示が増えない」をここでも守る —— ⚠ **見た目だけ満たしても通信は
/// 増える**ので、呼び出し側は `ref.watch` より手前でこれを見ること。
///
/// ⚠ **出すのは未購入（absent）と失効（expired）だけ。**
///
/// | 状態 | 入口 | 理由 |
/// | --- | --- | --- |
/// | `absent` / `expired` | ✅ 出す | 買えば直る |
/// | `active` | ❌ 出さない | ⚠⚠ **二重購入になる** |
/// | `grace` | ❌ 出さない | ⚠ **購読は生きている。**直し方はストアでの支払い方法の更新で、買い直しではない |
/// | `refunded` | ❌ 出さない | ⚠ 決済済みの期間が残っていて**まだ届いている**（relay#63） |
bool showRelayPurchaseEntry({
  required bool hasPreset,
  required EntitlementView view,
}) {
  if (hasPreset) return false;
  return view == EntitlementView.absent || view == EntitlementView.expired;
}

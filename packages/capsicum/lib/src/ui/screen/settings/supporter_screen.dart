import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../constants.dart';
import '../../../provider/supporter_purchase_provider.dart';
import '../../../provider/supporter_status_provider.dart';
import '../../util/launch_url_toast.dart';
import '../../widget/relay_entitlement_purchase_section.dart';
import '../../widget/section_header.dart';

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
      // 同じ文面だと**買ったものを取り違えて伝える**。⚠ **文面は
      // [supporterPurchaseOutcomeMessage] が正本** —— プッシュ通知設定画面にも
      // 購入の入口が増えたので (#1217)、分岐を写さない。
      messenger.showSnackBar(
        SnackBar(content: Text(supporterPurchaseOutcomeMessage(outcome))),
      );
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
          // ⚠⚠ **区切りは [SectionHeader]（グレーの帯）に寄せた (#1225)。**
          // 設定画面は他 3 つ（プッシュ通知 / アカウント / 外観）が帯を使って
          // `Divider` を 0 件にしており、**この画面だけが罫線 + 太字 Text で
          // 取り残されていた**。⚠ **帯と罫線を両方残さない** —— 二重の区切りに
          // なって、見やすくする目的に逆行する。
          ..._buildPurchaseSection(context, ref),
          const SectionHeader('事業者情報'),
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
        const SectionHeader('Web でのご支援'),
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
        const SectionHeader('投げ銭'),
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

    // ⚠⚠ **投げ銭を先に出す (#1225・2026-10-04 pooza)。**この画面は投げ銭の
    // ための画面なのに、利用権のほうが目立っていた。⚠ **以前のコメントは
    // 「機能に対する対価なので利用権が先」と書いていたが、これは実装時の判断で
    // 設計書の決定ではない**（`docs/paid-relay-plan.md` の決定済み事項 3 は
    // 「投げ銭を残したままサブスクを追加する」としか言っていない）。
    //
    // ⚠⚠ **注記は節ごと動かす。**「投げ銭は単発のお支払いです」を置き去りに
    // すると利用権の直下に出て、**サブスクを単発だと誤読させる。**
    return [
      const SectionHeader('投げ銭'),
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
      ..._subscriptionSection(state),
    ];
  }

  /// 有償リレーの利用権サブスク (#597 / #1122)。
  ///
  /// ⚠⚠ **投げ銭を置き換えない。**設計書 決定済み事項 3 のとおり「既存の投げ銭は
  /// 残したまま、サブスクを**追加**する」。
  ///
  /// ⚠⚠ **並べる順は投げ銭が先** (#1225・2026-10-04 pooza)。**この画面は投げ銭の
  /// ための画面**なので、利用権が目立っていてはいけない。⚠ 以前は「機能に対する
  /// 対価なので利用権が先」としていたが、**それは実装時の判断で設計書の決定では
  /// なかった。再提案しない。**
  ///
  /// ⚠⚠ **中身は [RelayEntitlementPurchaseSection] に移した (#1217)。**プッシュ
  /// 通知設定画面にも同じ入口を出すので、**購入の実装・「利用中」表示・商品が
  /// 取れないときの取り扱いを 1 本に保つ**ため。ここに残るのは見出しだけ。
  ///
  /// ⚠ **法定表記は節へ寄せない**（`showLegalNotice: false`）。この画面のものは
  /// **投げ銭と共通の画面レベル表記**で、節へ移すと**サブスク商品が取れない回に
  /// 投げ銭の法定表記ごと消える。**
  List<Widget> _subscriptionSection(SupporterPurchaseState state) {
    // ⚠ 商品が無ければ見出しも出さない（ウィジェット側は空を返すが、それだけ
    // だと**帯だけが残る**）。
    if (state.subscription == null) return const [];

    return [
      // ⚠⚠ **グレーの帯で揃える (#1225)。**以前は太字 `Text` + `Divider` で、
      // 設定画面の他の画面と見え方が違っていた。綴りはプッシュ通知設定画面と
      // 同じ（#1226・capsicum-site の特商法表記の商品名と一致）。
      const SectionHeader('プッシュ通知リレーの利用権'),
      const RelayEntitlementPurchaseSection(
        showBenefit: true,
        showLegalNotice: false,
      ),
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

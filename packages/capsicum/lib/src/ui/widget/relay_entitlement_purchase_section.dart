import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/entitlement_status_provider.dart';
import '../../provider/supporter_purchase_provider.dart';
import '../../service/push_registration_service.dart';
import '../util/launch_url_toast.dart';
import 'term_link_text.dart';

/// プッシュ通知リレーの利用権の節 (#597 / #1122 / #1217 / #1224)。
///
/// ⚠⚠ **プッシュ通知設定画面とサポーター画面で、できることを完全に同じにする**
/// (#1224・2026-10-04 pooza)。節の中身はこの 1 本で、**状態表示・購入・取り直す・
/// 登録し直す・記録を消すの 5 つが両画面に揃う。**
///
/// > じぶんとしては、どちらかというと「プッシュ通知」だと思っていますが、
/// > 「投げ銭」側のほうが出来ることが多いです。この優先順位を逆にするか、
/// > または出来ることが全く同じであってほしいです。（2026-10-04 pooza）
///
/// 🔴 **以前は門が画面ごとに別で、`unverified` のときプッシュ通知画面に
/// 「取り直す」が出なかった** —— あちらは節を `absent` / `expired` でしか組まず、
/// `unverified` は #1123 の判断で「有効」側へ倒している。**ゲートに拒まれている
/// 人がいちばん最初に開く画面に、抜ける口が無かった** (#1219)。
///
/// ⚠⚠ **「節を出すか」の判定だけは呼び出し側に残す。**プッシュ通知画面が
/// プリセット利用者に出さないのは #1123 の完了条件 3（無償のまま何も変わらない
/// 人に課金の状態を見せない）で、**買いに来た画面であるサポーター画面に同じ門は
/// 当てられない**。⚠⚠ **このウィジェットは [entitlementStatusProvider] と
/// [supporterPurchaseProvider] を `watch` するので、組んだ時点で relay への
/// 問い合わせとストアへの商品問い合わせが走る** —— 呼び出し側は `watch` より
/// 手前で門を置くこと。
///
/// ⚠ **採らなかった形**: 画面ごとに購入を作り直す —— 法定表記・解約の説明・
/// 二重購入の防止を 2 箇所に複写することになる。
class RelayEntitlementPurchaseSection extends ConsumerWidget {
  /// 便益の説明を添えるか。
  ///
  /// ⚠ **プッシュ通知設定画面では false。**状態別の文面が同じことを既に
  /// 言っているので、**足すと同じ説明が 2 回出る。**
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
    final status = ref.watch(entitlementStatusProvider);
    final state = ref.watch(supporterPurchaseProvider);
    final product = state.subscription;
    final view = status.view;
    final (title, body, icon) = relayEntitlementStatusCopy(
      view: view,
      expiresAt: status.expiresAt,
    );
    final busy = state.purchaseInProgress;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showBenefit)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            // ⚠⚠ **用語を「プリセットサーバー」へ揃え、説明へリンクした**
            // (#1221・2026-10-05 pooza 決定)。⚠ 以前は「capsicum の運営元が
            // 用意したサーバー」と**別の言い方**で書いていた —— 審査する人に
            // 便益を伝えるための言い換えだったが、**この画面だけ用語が違う**
            // 状態になっていた。⚠ リンクが説明を担うので、言い換えは要らない。
            child: TermLinkText(
              term: 'プリセットサーバー',
              url: AppConstants.presetServersUrl,
              // ⚠ **便益を正確に書く。**プリセットサーバーの利用者は元から無償で
              // 使えるので、「これを買わないと通知が来ない」ではない。
              // ⚠ 語は 2 回出るが、光るのは最初の 1 回だけ（[TermLinkText]）。
              text:
                  'プリセットサーバー以外でも、プッシュ通知を'
                  '受け取れるようになります。プリセットサーバーをお使いの方は、'
                  '購入しなくてもこれまでどおり通知を受け取れます。',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        // ⚠⚠ **状態表示は商品が取れなくても出す。**サブスクを扱えない OS や
        // ストアに繋がらない回でも、**「なぜ届かないのか」は言えなければ
        // ならない**（これが #1123 の出発点）。
        ListTile(leading: Icon(icon), title: Text(title), subtitle: Text(body)),
        // ⚠ **商品が取れなければ、買う / 取り直す側は丸ごと出さない** ——
        // ストア未登録・審査前・サブスクを扱えない OS。**押しても買えない入口を
        // 作らない。**
        if (product != null) ...[
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: Text(product.title),
            subtitle: Text(product.description),
            // ⚠⚠ **持っている人に購入ボタンを出さない**（二重購入の防止）。
            // 1 つの購入を複数端末で使えるので、押させると二重に払わせる。
            // ⚠ 判定は [showRelayPurchaseButton]（relay の見立てで切る）。
            // ⚠⚠ **ボタンを出さないときも価格は残す (#1232・2026-10-05 pooza)。**
            // 🔴 価格は**ボタンの文字にしか無かった**ので、ボタンを消すと
            // 「有料である」という情報ごと消えていた。⚠ **外部の利用者には
            // 有料だという情報は、プリセットの利用者にとっても無価値ではない。**
            trailing: showRelayPurchaseButton(view: view)
                ? FilledButton(
                    onPressed: busy
                        ? null
                        : () => ref
                              .read(supporterPurchaseProvider.notifier)
                              .subscribe(product),
                    child: Text(product.price),
                  )
                : Text(
                    product.price,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
          ),
          // ⚠⚠ **プリセットの利用者には、購入にまつわる操作を出さない**
          // （[showRelayEntitlementActions]・#1232 の続き）。
          if (showRelayEntitlementActions(view: view))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              // ⚠ 狭幅で溢れさせない（デスクトップは狭幅運用が前提）。
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  // ⚠⚠ **どの状態でも出す (#1219)。**機種変更・再インストールの
                  // 復元（トークンは `ThisDeviceOnly` でバックアップに入らない）と、
                  // `unverified` で固着したときに**アプリ内から抜ける唯一の口**を
                  // 兼ねる。⚠ App Store のガイドライン 3.1.1 でも要る。
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => ref
                              .read(supporterPurchaseProvider.notifier)
                              .restoreEntitlement(),
                    child: const Text('利用権を取り直す'),
                  ),
                  // ⚠⚠ **買い直したあとの再登録の導線。**`/push` が 410 を返すと
                  // fedi サーバー側の購読が消えるので、⚠ **買い直すだけでは
                  // 戻らない。**⚠ 返金済みにも出す（いまは届いているが期限で
                  // 切れるので、買い直したときにここから戻せる必要がある）。
                  if (view != EntitlementView.active)
                    OutlinedButton(
                      onPressed: busy ? null : () => _reconcile(ref),
                      child: const Text('購入を確認して登録し直す'),
                    ),
                  // 🔴 **取り直しが空振りしたときの出口 (#1219)。**relay が認めない
                  // トークンを持っていると「有効」側へ倒れて購入ボタンが出ず、
                  // 取り直しても何も起きない。⚠ **手元の保存がある人にだけ出す。**
                  if (state.hasEntitlement)
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => _confirmForget(context, ref),
                      child: const Text('利用権の記録を消す'),
                    ),
                ],
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
      ],
    );
  }

  /// 利用権を引き直して、全アカウントの購読を登録し直す (#1123 / #1217)。
  ///
  /// ⚠⚠ **買っただけでは戻らない。**`/push` が 410 を返していた間に fedi
  /// サーバー側の購読が destroy されているので（relay#63 の決着どおり）、
  /// **登録をやり直すまで通知は届かない。**
  Future<void> _reconcile(WidgetRef ref) async {
    await ref.read(entitlementStatusProvider.notifier).refresh();
    final accounts = ref.read(accountManagerProvider).accounts;
    if (accounts.isNotEmpty) {
      await PushRegistrationService.registerAllAccounts(accounts);
    }
  }

  /// 「記録を消す」を確認してから実行する (#1219)。
  ///
  /// ⚠⚠ **確認なしで消さない。**有効な利用権を持っている人が押すと、
  /// **取り直すまで通知が止まる**。⚠ **何が消えて何が消えないか**を文面で
  /// 分ける —— ストアの購読は解約されない。
  Future<void> _confirmForget(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('利用権の記録を消しますか？'),
        content: const Text(
          'この端末に保存した利用権の記録を消します。\n\n'
          '・ご購入そのものは消えません。ストアの購読は解約されません\n'
          '・「利用権を取り直す」で引き直せます\n'
          '・消すと、買い直しのボタンが出るようになります\n\n'
          '取り直しても直らないときにお使いください。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('消す'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(supporterPurchaseProvider.notifier).forgetEntitlement();
    // ⚠ 消しただけでは画面が古い状態のままなので引き直す（`absent` へ落ちる）。
    await ref.read(entitlementStatusProvider.notifier).refresh();
  }
}

/// 利用権の状態を伝える文面 (#1123 / #1224)。
///
/// ⚠⚠ **2 画面で同じものを出すので 1 本にしてある** (#1224)。以前はプッシュ通知
/// 設定画面の中にだけあり、サポーター画面には状態表示そのものが無かった。
///
/// [expiresAt] は relay が返した生の文字列。読めなければ null でよい
/// （[formatEntitlementExpiry] が null を返し、文面から日付だけが落ちる）。
(String, String, IconData) relayEntitlementStatusCopy({
  required EntitlementView view,
  required String? expiresAt,
}) {
  final expiry = formatEntitlementExpiry(expiresAt);
  return switch (view) {
    EntitlementView.active => (
      '利用権は有効です',
      'プリセット以外のサーバーでもプッシュ通知を受け取れます。',
      Icons.check_circle_outline,
    ),
    // ⚠⚠ **届いている。**relay は返金済みでも**決済済みの期間までは通す**
    // （relay#63「払った分の権利は否定しない」）。⚠ **失効と同じ文面にしない** ——
    // 届いているのに「届かなくなります」と言うことになる。
    // ⚠ **期限を併記する**のがこの状態の存在理由。
    EntitlementView.refunded => (
      '返金済みです',
      expiry == null
          ? '決済済みの期間が残っているあいだは、プリセット以外のサーバーでも'
                'プッシュ通知をお使いいただけます。'
          : '$expiry までは、プリセット以外のサーバーでもプッシュ通知を'
                'お使いいただけます。期限を過ぎると届かなくなります。',
      Icons.schedule,
    ),
    // ⚠⚠ **止まっている。**2026-10-03 に「未払いの間は通さない」と決まった
    // （relay#63）ので、**「いまのところ届いています」とは言えない。**
    // ⚠ **利用者が自分で直せる唯一の状態**なので、直し方まで書く。
    EntitlementView.grace => (
      'お支払いを確認できていません',
      'プリセット以外のサーバーへのプッシュ通知が止まっています。'
          'ストアでお支払い方法をご確認ください。'
          'お支払いが確認できたあと、この節から登録をやり直すと再び届きます。',
      Icons.error_outline,
    ),
    EntitlementView.expired => (
      '利用権が失効しています',
      'プリセット以外のサーバーでは、プッシュ通知が届かなくなります。'
          'もう一度ご購入いただくと、この節から登録をやり直せます。',
      Icons.cancel_outlined,
    ),
    // ⚠⚠ **「サポート画面から」と書かない (#1217)。**購入の入口がこの節の
    // すぐ下に出るので、**辿り直させる案内が残ると誤導になる。**
    EntitlementView.absent => (
      '利用権がありません',
      // ⚠⚠ **「プリセット以外のサーバーで」と書かない (#1232)。**この文面が
      // 出るのは**プリセットのアカウントを 1 つも持たない人**なので、その人に
      // とっては**どのサーバーでも届かない**。⚠ 「プリセット以外では届かない」
      // と書くと、**「プリセットでだけ使える権利を持っている」という存在しない
      // 状態**を前提にした説明になる。
      'プッシュ通知を受け取るには、利用権のご購入が必要です。',
      Icons.info_outline,
    ),
    // ⚠⚠ **プリセットの利用者には「無い」と言わない (#1232)。**課金の状態を
    // 見せるだけでも不変条件に触れる（`docs/product-policy.md`）。⚠ **既に
    // 使えている**ことを言い、購入の話をしない。
    EntitlementView.preset => (
      'プッシュ通知をご利用いただけます',
      // ⚠⚠ **購入に言及しない。**「購入は必要ありません」も**課金の話を
      // 持ち出している**ことに変わりはない。⚠ 便益の説明（この節の上）が
      // 「プリセットサーバーをお使いの方は、購入しなくてもこれまでどおり
      // 通知を受け取れます」と既に言っているので、ここで繰り返す必要もない。
      'プリセットサーバーのアカウントをお持ちなので、'
          'すべてのアカウントでプッシュ通知が届きます。',
      Icons.check_circle_outline,
    ),
  };
}

/// 購入結果の文面 (#1122 / #1217)。
///
/// ⚠⚠ **2 画面で同じ文面を使うので 1 本にしてある。**購入の入口が増えた
/// (#1217) ことで、⚠ **写すと「買ったものを取り違えて伝える」分岐が 2 箇所に
/// 散る**（投げ銭とサブスクで成功の意味が違う）。
///
/// ⚠ **スナックバーの `ref.listen` は画面側に置く。**節の中で待ち受けると、
/// 画面を離れる操作と競合して**結果を出す前に unmount されうる。**
String supporterPurchaseOutcomeMessage(SupporterPurchaseOutcome outcome) =>
    switch ((outcome.kind, outcome.isSubscription)) {
      (SupporterPurchaseOutcomeKind.success, true) =>
        'ありがとうございます！プッシュ通知リレーの利用権が有効になりました。',
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

/// 購入ボタン（買う / 買い直す）を出すか (#1217 / #1219)。
///
/// 判断材料が enum だけなので、ウィジェットから切り出してテスト可能にしてある。
///
/// ⚠⚠ **以前は `hasPreset` も材料にしていた** (`showRelayPurchaseEntry`)。
/// **節そのものを出すかの門は呼び出し側に移した** (#1224) ので、ここは
/// 「買える状態か」だけを見る。
///
/// ⚠⚠ **`hasEntitlement`（手元のトークンの有無）で切らない (#1219)。**
/// 🔴 **失効しても手元のトークンは残る**ので、それで切ると**買い直せない**
/// （「取り直す」しか出ない）。⚠ **判定は relay の見立て（[EntitlementView]）**。
///
/// | 状態 | 購入ボタン | 理由 |
/// | --- | --- | --- |
/// | `absent` | ✅ 出す | 買っていない |
/// | `expired` | ✅ 出す | ⚠ **買い直せないと詰む** |
/// | `active` | ❌ 出さない | ⚠⚠ **二重購入になる** |
/// | `grace` | ❌ 出さない | ⚠ **購読は生きている。**直し方はストアでの支払い方法の更新 |
/// | `refunded` | ❌ 出さない | ⚠ 決済済みの期間が残っていて**まだ届いている**（relay#63） |
/// ⚠⚠ **[EntitlementView.preset] では出さない (#1232)。**プリセットの利用者に
/// 購入ボタンを出すのは、`docs/product-policy.md` の不変条件でいう
/// **「課金を促す」**に当たる。⚠ **買えなくするのではなく、勧めない** ——
/// 投げ銭はこの画面の本来の目的として従来どおり出る。
bool showRelayPurchaseButton({required EntitlementView view}) =>
    view == EntitlementView.absent || view == EntitlementView.expired;

/// 「利用権を取り直す」「購入を確認して登録し直す」「利用権の記録を消す」を
/// 出すか (#1232 の続き・2026-10-06 pooza)。
///
/// ⚠⚠ **[EntitlementView.preset] では出さない。**#1232 は購入ボタンしか
/// 消しておらず、プリセットの利用者に**買っていないものを「取り直す」「購入を
/// 確認する」と勧めていた**。購入ボタンと同じく、これも課金の話を持ち出して
/// いる（`docs/product-policy.md` の不変条件）。
///
/// ⚠ **プリセットの人が実際に購入していても出さない。**`EntitlementStatusNotifier`
/// が「プリセットなら購入の状態を出さない」としているのと同じ線で、解約は
/// もともとストア側でしかできないので、アプリから消えても失われる導線は無い。
/// プリセットのアカウントがある限り、3 つとも**押しても届き方が変わらない**。
///
/// ⚠ **それ以外の状態では従来どおり全部の判定を通す**（「取り直す」は機種変更・
/// 再インストールからの復元の口なので、`absent` でも出す・#1219）。
bool showRelayEntitlementActions({required EntitlementView view}) =>
    view != EntitlementView.preset;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/entitlement_status_provider.dart';
import '../../provider/supporter_purchase_backend.dart';
import '../../provider/supporter_purchase_provider.dart';
import '../../service/push_registration_service.dart';
import '../util/launch_url_toast.dart';
import 'term_link_text.dart';

/// プッシュ通知リレーの利用権の節 (#597 / #1122 / #1217 / #1224)。
///
/// ⚠⚠ **プッシュ通知設定画面とサポーター画面で、できることを完全に同じにする**
/// (#1224・2026-10-04 pooza)。節の中身はこの 1 本で、**状態表示・購入・復元
/// （登録のやり直しを含む）・記録を消すの 4 つが両画面に揃う。**⚠ #1234 までは
/// 復元が「取り直す」と「登録し直す」の 2 つに分かれていて、5 つだった。
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
    // ⚠ プリセットの利用者には出さない（購入の話をしない・#1232）。届かない
    // アカウントがあること自体は、プッシュ通知設定のアカウント行が伝える。
    final unsupportedNote = view == EntitlementView.preset
        ? null
        : relayUnsupportedAccountNote([
            for (final account
                in PushRegistrationService.accountsWithoutPushSupport(
                  ref.watch(accountManagerProvider).accounts,
                ))
              '@${account.key.username}@${account.key.host}',
          ]);

    // ⚠⚠ **購入・復元が成立したら、利用権の状態を引き直す (#1234)。**
    //
    // 🔴 **以前はプッシュ通知設定画面にしか無かった。**購入ボタンを出すかは
    // relay の見立て（[showRelayPurchaseButton]）で決めているのに、サポーター
    // 画面は成立後も引き直さなかったので、**買った直後も「利用権がありません」と
    // 購入ボタンが残り、二重購入を誘っていた**（#1224 で判定を手元のトークンから
    // 見立てへ変えたときに取り残された）。⚠ **節の中へ置けば、2 画面とも揃う。**
    ref.listen<SupporterPurchaseState>(supporterPurchaseProvider, (prev, next) {
      final outcome = next.lastOutcome;
      if (outcome == null || outcome == prev?.lastOutcome) return;
      if (!outcome.isSubscription) return;
      if (outcome.kind != SupporterPurchaseOutcomeKind.success) return;
      ref.read(entitlementStatusProvider.notifier).refreshCoalesced();
    });

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
        // ⚠⚠ **買っても届かないアカウントを、買う前に知らせる (2026-10-06
        // pooza)。**モロヘイヤの中継が無い Misskey は、サーバーソフトウェアの仕様で
        // 購読を登録できない。🔴 黙っていると**月額を払ってから「対応して
        // いません」と知る**ことになる。⚠ 当たるアカウントを持つ人にしか出ない。
        if (unsupportedNote != null)
          ListTile(
            leading: Icon(
              Icons.warning_amber_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
            subtitle: Text(unsupportedNote),
          ),
        // ⚠ **商品が取れなければ、買う / 復元する側は丸ごと出さない** ——
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ⚠ 狭幅で溢れさせない（デスクトップは狭幅運用が前提）。
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      // ⚠⚠ **復元と登録のやり直しは 1 つのボタン (#1234・2026-10-06
                      // pooza)。**以前は「利用権を取り直す」と「購入を確認して
                      // 登録し直す」に分かれていたが、**名前から違いが読めなかった**
                      // （前者は「買い直す」に、後者は「ストアに問い合わせる」に
                      // 読めて、実際は逆）。
                      //
                      // ⚠⚠ **どの状態でも出す (#1219)。**機種変更・再インストールの
                      // 復元（トークンは `ThisDeviceOnly` でバックアップに入らない）、
                      // `unverified` で固着したときに**アプリ内から抜ける唯一の口**、
                      // 支払いを直したあとの再登録（`/push` が 410 を返すと fedi
                      // サーバー側の購読が消えるので、**直すだけでは戻らない**）を
                      // 兼ねる。⚠ App Store のガイドライン 3.1.1 が求める
                      // 「購入を復元する手段」でもあるので、**名前を「復元」から
                      // 離さない**。
                      OutlinedButton(
                        onPressed: busy ? null : () => _restore(ref),
                        child: const Text('購入を復元する'),
                      ),
                      // 🔴 **復元が空振りしたときの出口 (#1219)。**relay が認めない
                      // トークンを持っていると「有効」側へ倒れて購入ボタンが出ず、
                      // 復元しても何も起きない。⚠ **手元の保存がある人にだけ出す。**
                      if (state.hasEntitlement)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => _confirmForget(context, ref),
                          child: const Text('利用権の記録を消す'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // ⚠⚠ **「お支払いは発生しません」を必ず言う (#1234)。**「復元」は
                  // 買い直しと取り違えられやすく、押すのをためらわせる。
                  const Text(
                    'お支払いは発生しません。機種変更のあとや、通知が届かないときに'
                    'お試しください。',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              // ⚠ 解約の窓口はストア。⚠⚠ **アプリ内に解約導線を作らない**
              // （ストアの規約上、アプリから直接は解約できない）。
              // ⚠⚠ **ストアの名前は、そのストアの版にだけ出す**
              // （[relayCancellationNote]）。
              relayCancellationNote(store: entitlementStoreName()),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          // ⚠⚠ **利用規約とプライバシーポリシーは、購入ボタンのある面に必ず出す**
          // （2026-10-08 pooza）。自動更新サブスクを持つアプリは、**アプリの中に**
          // この 2 つへのリンクを求められる（ストアの説明文のリンクとは別の要件）。
          // 🔴 以前は初回起動の同意画面にしか無く、同意した後は辿れなかった。
          // ⚠ **[showLegalNotice] に掛けない** —— あちらは投げ銭と共通の特商法
          // 表記を二重にしないための門で、この 2 つは両画面とも節にしか無い。
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('利用規約'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => launchUrlOrToast(context, AppConstants.termsUrl),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('プライバシーポリシー'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () =>
                launchUrlOrToast(context, AppConstants.privacyPolicyUrl),
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

  /// 購入を復元し、登録をやり直して、状態を引き直す (#1234)。
  ///
  /// ⚠⚠ **登録の実体は provider 側に 1 本**（`restoreAndReregister`）。ここで
  /// `registerAllAccounts` を打たない —— 復元で購入が返った回は既存の経路が
  /// 登録をやり直すので、**ここでも打つと二重になる**（#1217）。
  ///
  /// ⚠ **購入が返った回の引き直しは [build] の listener が担う。**その回は
  /// relay からの発行と保存が**まだ終わっていない**ので、ここで引き直しても
  /// 古い値を読む。返らなかった回だけ、ここで引き直す。
  ///
  /// ⚠⚠ **`ref` は待つ前に使い切る。**復元と登録は合わせて 20 秒以上かかりうる
  /// ので、その間に画面を離れると `ref` は使えなくなる（`ref.read` が例外を
  /// 投げ、引き直しも走らない）。notifier を先に取り出しておけば、画面が
  /// 無くなっても最後まで走る。
  Future<void> _restore(WidgetRef ref) async {
    final purchase = ref.read(supporterPurchaseProvider.notifier);
    final status = ref.read(entitlementStatusProvider.notifier);
    final restored = await purchase.restoreAndReregister();
    if (restored) return;
    await status.refresh();
  }

  /// 「記録を消す」を確認してから実行する (#1219)。
  ///
  /// ⚠⚠ **確認なしで消さない。**有効な利用権を持っている人が押すと、
  /// **取り直すまで通知が止まる**。⚠ **何が消えて何が消えないか**を文面で
  /// 分ける —— ストアの購読は解約されない。
  Future<void> _confirmForget(BuildContext context, WidgetRef ref) async {
    // ⚠ `ref` は待つ前に使い切る（[_restore] と同じ理由）。
    final purchase = ref.read(supporterPurchaseProvider.notifier);
    final status = ref.read(entitlementStatusProvider.notifier);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('利用権の記録を消しますか？'),
        content: const Text(
          'この端末に保存した利用権の記録を消します。\n\n'
          '・ご購入そのものは消えません。ストアでの自動更新も止まりません\n'
          '・「購入を復元する」で元に戻せます\n'
          '・消すと、買い直しのボタンが出るようになります\n\n'
          '復元しても直らないときにお使いください。',
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
    await purchase.forgetEntitlement();
    // ⚠ 消しただけでは画面が古い状態のままなので引き直す（`absent` へ落ちる）。
    await status.refresh();
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
  // ⚠⚠ **どの状態でも「プリセット以外のサーバーでは」と書かない**（#1232 の
  // 続き・リリース前レビュー 2026-10-06）。プリセットのアカウントを持つ人は
  // [EntitlementView.preset] へ行くので、**ここから下の文面を読むのは全員
  // 「プリセットを持たない人」**。その人にとっては**どのサーバーでも**同じ話で、
  // 「プリセット以外では」と限定すると、**プリセットでだけ使える権利を持って
  // いる**という存在しない状態を前提にした説明になる。⚠ 以前は `absent` だけ
  // 直して、ほかの 4 状態に残していた。
  return switch (view) {
    EntitlementView.active => (
      '利用権は有効です',
      'プッシュ通知を受け取れます。',
      Icons.check_circle_outline,
    ),
    // ⚠⚠ **届いている。**relay は返金済みでも**決済済みの期間までは通す**
    // （relay#63「払った分の権利は否定しない」）。⚠ **失効と同じ文面にしない** ——
    // 届いているのに「届かなくなります」と言うことになる。
    // ⚠ **期限を併記する**のがこの状態の存在理由。
    EntitlementView.refunded => (
      '返金済みです',
      expiry == null
          ? '決済済みの期間が残っているあいだは、プッシュ通知をお使いいただけます。'
          : '$expiry までは、プッシュ通知をお使いいただけます。'
                '期限を過ぎると届かなくなります。',
      Icons.schedule,
    ),
    // ⚠⚠ **止まっている。**2026-10-03 に「未払いの間は通さない」と決まった
    // （relay#63）ので、**「いまのところ届いています」とは言えない。**
    // ⚠ **利用者が自分で直せる唯一の状態**なので、直し方まで書く。
    // ⚠ **操作は実在するボタンの名前で指す。**#1234 で「登録し直す」は
    // 「購入を復元する」にまとまったので、「この節から登録をやり直す」という
    // 名前の操作はもう無い。
    EntitlementView.grace => (
      'お支払いを確認できていません',
      'プッシュ通知が止まっています。ストアでお支払い方法をご確認ください。'
          'お支払いが確認できたあと、下の「購入を復元する」を押すと再び届きます。',
      Icons.error_outline,
    ),
    EntitlementView.expired => (
      '利用権が失効しています',
      'プッシュ通知が届かなくなります。'
          'もう一度ご購入いただくと、再び届くようになります。',
      Icons.cancel_outlined,
    ),
    // 🔴 **「分からない」を「無い」と言わない**（リリース前レビュー
    // 2026-10-06）。端末の保存を読めなかっただけで、購入済みかもしれない。
    // ⚠ 購入を勧める語（「ご購入」）を入れない。
    EntitlementView.unknown => (
      '利用権の状態を確認できませんでした',
      '端末に保存した情報を読み出せませんでした。'
          // ⚠ **実在する操作を指す**（2 回目の差分レビュー・2026-10-06）。以前は
          // 「もう一度この画面を開いてください」だったが、画面を開き直しても
          // 読み直さない（読み直すのは起動時と、購入・復元のあと）。
          'アプリを開き直すと、もう一度確認します。',
      Icons.help_outline,
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
String supporterPurchaseOutcomeMessage(
  SupporterPurchaseOutcome outcome,
) => switch ((outcome.kind, outcome.isSubscription)) {
  (SupporterPurchaseOutcomeKind.success, true) =>
    'ありがとうございます！プッシュ通知リレーの利用権が有効になりました。',
  (SupporterPurchaseOutcomeKind.success, false) => 'ありがとうございます！サポーターになりました。',
  (SupporterPurchaseOutcomeKind.canceled, _) => '購入をキャンセルしました。',
  // ストアでの購入が成立しなかった（投げ銭もサブスクも同じ）。
  (SupporterPurchaseOutcomeKind.error, _) => '購入を完了できませんでした。時間をおいて再度お試しください。',
  // ⚠ サブスクは購入が成立していても利用権の発行で落ちることがある
  // （relay へ届かない等）。⚠⚠ **「購入できなかった」と言い切らない。**
  (SupporterPurchaseOutcomeKind.entitlementError, _) =>
    '利用権を有効にできませんでした。時間をおいてアプリを開き直してください。',
  (SupporterPurchaseOutcomeKind.restoreError, _) =>
    '購入を復元できませんでした。時間をおいて再度お試しください。',
  // ⚠ 失敗ではない。**買っていない人が押しても出る**ので、責める言い方に
  // しない。
  (SupporterPurchaseOutcomeKind.nothingToRestore, _) => '復元できる購入が見つかりませんでした。',
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

/// 利用権を買っても届かないアカウントがあることを伝える文面 (2026-10-06 pooza)。
/// 該当が無ければ null。
///
/// [labels] は `@ユーザー名@ホスト` の列
/// （`PushRegistrationService.accountsWithoutPushSupport` に当たったもの）。
///
/// ⚠⚠ **「買っても届かない」を言い切る。**「届かない場合があります」とぼかすと、
/// 読んだ人は自分が当たるのか分からない。⚠ **理由は一言だけ**（サーバー
/// ソフトウェアの仕様）—— 仕組みの説明は capsicum-site のプッシュ通知ページに
/// ある。⚠ 特定のサーバーを責める書き方にしない。
String? relayUnsupportedAccountNote(List<String> labels) {
  if (labels.isEmpty) return null;
  if (labels.length == 1) {
    return '${labels.single} のサーバーは、サーバーソフトウェアの仕様により'
        'プッシュ通知に対応していません。利用権を購入しても、このアカウントには'
        '届きません。';
  }
  return '次のアカウントのサーバーは、サーバーソフトウェアの仕様により'
      'プッシュ通知に対応していません。利用権を購入しても、これらのアカウントには'
      '届きません。\n${labels.join('\n')}';
}

/// 自動更新と解約の窓口を伝える文面 (2026-10-06 pooza)。
///
/// ⚠⚠ **ほかのストアの名前を出さない。**以前は全プラットフォームで
/// 「ご利用のストア」に続けて Apple と Google の両方のストア名を並べていたが、
/// **iOS 版に「Google Play」と書くのは App Store Review Guideline 2.3.10**
/// （ほかのモバイルプラットフォームの名前をアプリ内に出さない）に当たりうる。
/// 利用者にとっても、自分に関係のないストアの名前は余計。
///
/// [store] は `entitlementStoreName()` の値（`apple` / `google` / `microsoft` /
/// null）。⚠ **`Platform` をここで見ない** —— 引数で受ければ、どの端末の上でも
/// 全部の分岐を検査できる。⚠ 知らない値はストア名を出さない側へ倒す。
String relayCancellationNote({required String? store}) => switch (store) {
  'apple' => '毎月の自動更新です。解約は App Store のサブスクリプションの設定から行えます。',
  'google' => '毎月の自動更新です。解約は Google Play の定期購入から行えます。',
  _ => '毎月の自動更新です。解約はご利用のストアから行えます。',
};

/// 「購入を復元する」「利用権の記録を消す」（と添え書き）を出すか
/// (#1232 の続き・2026-10-06 pooza)。
///
/// ⚠⚠ **[EntitlementView.preset] では出さない。**#1232 は購入ボタンしか
/// 消しておらず、プリセットの利用者に**買っていないものを「復元する」と
/// 勧めていた**。購入ボタンと同じく、これも課金の話を持ち出して
/// いる（`docs/product-policy.md` の不変条件）。
///
/// ⚠ **プリセットの人が実際に購入していても出さない。**`EntitlementStatusNotifier`
/// が「プリセットなら購入の状態を出さない」としているのと同じ線で、解約は
/// もともとストア側でしかできないので、アプリから消えても失われる導線は無い。
/// プリセットのアカウントがある限り、どれも**押しても届き方が変わらない**。
///
/// ⚠ **それ以外の状態では従来どおり全部の判定を通す**（復元は機種変更・
/// 再インストールから戻る口なので、`absent` でも出す・#1219）。
bool showRelayEntitlementActions({required EntitlementView view}) =>
    view != EntitlementView.preset;

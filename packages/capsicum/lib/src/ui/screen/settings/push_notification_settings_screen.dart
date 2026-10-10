import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../constants.dart';
import '../../../model/account.dart';
import '../../../provider/account_manager_provider.dart';
import '../../../provider/entitlement_status_provider.dart';
import '../../../provider/push_registration_status_provider.dart';
import '../../../provider/supporter_purchase_provider.dart';
import '../../../service/announcement_subscription_service.dart';
import '../../../service/push_registration_service.dart';
import '../../../service/push_registration_status.dart';
import '../../widget/push_registration_status_section.dart';
import '../../widget/relay_entitlement_purchase_section.dart';
import '../../widget/section_header.dart';
import '../../widget/term_link_text.dart';

/// プッシュ通知の登録状態をアカウント別に一覧表示し、失敗していれば
/// 再試行できる設定画面（#340）。
///
/// 「eligible」の解釈は [PushRegistrationService.registerAllAccounts] と
/// 揃える — プリセットサーバーのアカウントが 1 つでもあれば、非プリセット
/// アカウントも登録対象になる。UI 側もこの eligibility に従って表示・
/// リトライ可否を出し分ける。
class PushNotificationSettingsScreen extends ConsumerWidget {
  const PushNotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountManagerProvider).accounts;
    final statusMap =
        ref.watch(pushRegistrationStatusProvider).valueOrNull ??
        const <String, PushRegistrationSnapshot>{};
    // 🔴 **接続できていないプリセットのアカウントも数える**
    // （[hasPresetAccountProvider]）。`accounts` だけで判定すると、プリセットの
    // サーバーに届かない日に、併用している人へ購入を促す。
    final hasPreset = ref.watch(hasPresetAccountProvider);

    // 利用権の状態 (#1123 / #1217 / #1218)。
    //
    // ⚠⚠ **`watch` より先に `hasPreset` で抜ける。**プリセットのみの人に対して
    // は利用権の provider も購入の provider も起動させない（#1123 の完了条件 3・
    // ⚠ **見た目だけ満たしても通信は増える**）。
    final entitlementView = hasPreset
        ? EntitlementView.absent
        : ref.watch(entitlementStatusProvider).view;

    // ⚠⚠ **手元に利用権があるか** —— `absent` 以外＝トークンを持っている、
    // **または読めなくて分からない**（`unknown`）。分からない回も登録は試みる。
    // **登録を試みる側の判定に使う** (#1218)。⚠ **`status` では切らない**
    // （`expired` でも登録は試みて、止めるのは relay の仕事）。
    final hasEntitlement = attemptsRegistrationWith(entitlementView);

    // 利用権の購入結果を知らせ、この画面の表示を購入後の状態へ追いつかせる
    // (#1217)。
    //
    // ⚠⚠ **画面側で待ち受ける。**[RelayEntitlementPurchaseSection] は購入が
    // 成立すると消える側なので、ウィジェットに置くと**結果を出す前に unmount
    // されうる。**
    //
    // ⚠⚠ **再登録はここでやらない。**[SupporterPurchaseNotifier] の
    // `_completeAndReregister` が購入成立の時点で `registerAllAccounts` を
    // 打っている。🔴 **2026-10-04 の実機確認で、ここから二重に打っていたのを
    // 実測した**（relay の journald に `register.created` が 0.6 秒差で 2 本）。
    // ⚠ **足りないのは [entitlementStatusProvider] の引き直しだけ** ——
    // あちらは `refresh()` を呼ばれないと `absent` のままなので、買っても
    // 画面が「利用権がありません」のまま残る。
    //
    // ⚠ **投げ銭の結果は拾わない。**この画面に投げ銭の入口は無いので、
    // サポーター画面で買ったものの結果をここで出すと文脈が合わない。
    // ⚠⚠ **門は `hasPreset` だけにした (#1224)。**以前は「購入の入口が出る
    // とき」(`absent` / `expired`) に限っていたが、節のできることを 2 画面で
    // 揃えたので、**`unverified` で「購入を復元する」を押した結果もここで出す**
    // 必要がある。⚠ プリセットのみの人には節が出ないので待ち受けない。
    if (!hasPreset) {
      ref.listen<SupporterPurchaseState>(supporterPurchaseProvider, (
        prev,
        next,
      ) {
        final outcome = next.lastOutcome;
        if (outcome == null || outcome == prev?.lastOutcome) return;
        if (!outcome.isSubscription) return;
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(content: Text(supporterPurchaseOutcomeMessage(outcome))),
        );
        if (outcome.kind == SupporterPurchaseOutcomeKind.success) {
          ref.read(entitlementStatusProvider.notifier).refreshCoalesced();
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('プッシュ通知'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            // ⚠⚠ **用語からサイトの説明へ辿れるようにする (#1221)。**有償リレー
            // で「プリセットサーバー」が**課金の線引きそのもの**になったため、
            // 初めて見る人がここで詰まる。⚠ **光らせるのはこの画面で 1 箇所だけ**
            // （利用権の節には張らない・2026-10-05 pooza 決定）。
            child: TermLinkText(
              term: 'プリセットサーバー',
              url: AppConstants.presetServersUrl,
              text:
                  // ⚠⚠ **利用権がある場合を書き分ける (#1218)。**買った人に
                  // 「プリセットのアカウントが要ります」と出していた。
                  // ⚠ **分からない回は「ある」と言い切らない**（2 回目の差分
                  // レビュー・2026-10-06）。すぐ下の節が「確認できませんでした」と
                  // 出すので、ここで「利用権があるため」と言うと食い違う。
                  switch ((
                    hasPreset,
                    hasEntitlement &&
                        entitlementView != EntitlementView.unknown,
                  )) {
                    (true, _) =>
                      'プリセットサーバーのアカウントが登録されているため、'
                          'すべてのアカウントでプッシュ通知が利用できます。'
                          '登録に失敗した場合は、各アカウントの行から再試行できます。',
                    (false, true) =>
                      'プッシュ通知リレーの利用権があるため、すべてのアカウントで'
                          'プッシュ通知が利用できます。'
                          '登録に失敗した場合は、各アカウントの行から再試行できます。',
                    (false, false) =>
                      'プッシュ通知は、プリセットサーバーのアカウントが 1 つ以上'
                          '登録されているか、プッシュ通知リレーの利用権がある場合に'
                          '利用できます。',
                  },
              style: const TextStyle(fontSize: 13),
            ),
          ),
          ..._entitlementSection(ref, hasPreset: hasPreset),
          const SectionHeader('アカウント別の登録状況'),
          ...accounts.map(
            (account) => _AccountStatusTile(
              account: account,
              snapshot: statusMap[account.key.toStorageKey()],
              hasPreset: hasPreset,
              // ⚠ 行ごとに `watch` させない（親で 1 回引いて渡す・#1218）。
              hasEntitlement: hasEntitlement,
            ),
          ),
        ],
      ),
    );
  }

  /// 有償リレーの利用権の状態 (#597 / #1123)。
  ///
  /// ⚠⚠ **プリセットサーバーのアカウントがあるなら何も出さない。**無償のまま
  /// 何も変わらない人に課金の状態を見せない —— ゲートが閉じるのは
  /// **「非プリセット かつ 利用権なし」**のときだけで、⚠ **プリセットに 1 つでも
  /// アカウントがあれば全アカウントが通る**（設計書の意図どおりの「迂回」）。
  ///
  /// ⚠ **未購入でも、非プリセットの人には出す。**「いつのまにか通知が来ない」を
  /// 避けるのがこの Issue の出発点で、**買っていないこと自体が原因になりうる。**
  ///
  /// ⚠⚠ **中身は [RelayEntitlementPurchaseSection] に全部移した (#1224)。**
  /// ここに残るのは**見出しと「出すかどうか」の門だけ** —— サポーター画面と
  /// できることを完全に同じにするため。以前はこちらだけが状態表示と
  /// 「登録し直す」を持ち、あちらだけが「取り直す」を持っていた。
  List<Widget> _entitlementSection(WidgetRef ref, {required bool hasPreset}) {
    // ⚠⚠ **`watch` より先に抜ける。**ここで provider を起動すると、プリセットの
    // みの人でも**キーホルダの読み出しと relay への問い合わせが走る** ——
    // 「何も表示が増えない」を見た目だけで満たしても、**通信は増えている。**
    // ⚠ 下の [showEntitlementSection] も同じ判定を持つ（あちらは検査で固定した
    // 判断そのもの、ここは**起動させないための門**）。
    if (hasPreset) return const [];

    final status = ref.watch(entitlementStatusProvider);
    if (!showEntitlementSection(
      hasPreset: hasPreset,
      view: status.view,
      isRefreshing: status.isRefreshing,
    )) {
      return const [];
    }

    return [
      // ⚠⚠ **画面名と重複するが「プッシュ通知リレーの利用権」で統一する**
      // (#1226 案 A・2026-10-04 pooza)。購入ボタンが並ぶ面では商品名が曖昧で
      // ないほうがよく、**capsicum-site の特商法表記の商品名と完全一致する**。
      // ⚠ 「この見出しだけ短く」は検討の上で採らなかった（再提案しない）。
      const SectionHeader('プッシュ通知リレーの利用権'),
      // ⚠⚠ **中身は共有ウィジェット 1 本 (#1224)。**状態表示・購入・復元・
      // 記録を消すが、**サポーター画面と完全に同じ**出方になる（復元の口は
      // #1234 で 1 つにまとめた）。
      // ⚠ **ここで組み立て直さない** —— 以前はこちらだけが状態表示と
      // 「登録し直す」を持ち、あちらだけが「取り直す」を持っていた。
      const RelayEntitlementPurchaseSection(
        // ⚠ 便益は状態別の文面が言っているので重ねない。
        showBenefit: false,
        // ⚠⚠ **購入ボタンのある画面に法定表記が要る**（C-3）。
        showLegalNotice: true,
      ),
    ];
  }
}

/// 利用権の節を出すか (#597 / #1123)。
///
/// 判断材料が真偽値と enum だけなので、画面から切り出してテスト可能にしてある
/// （[resolveAnnouncementRow] と同じ流儀）。
///
/// ⚠⚠ **プリセットサーバーのアカウントがあるなら出さない**（完了条件の 3 つ目）。
/// 無償のまま何も変わらない人に課金の状態を見せない —— ゲートが閉じるのは
/// **「非プリセット かつ 利用権なし」**のときだけで、⚠ **プリセットに 1 つでも
/// アカウントがあれば全アカウントが通る**（設計書の意図どおりの「迂回」）。
///
/// ⚠ **読み込み中に「未購入」と出さない。**一瞬でも「買ってください」と見せると、
/// **買った人に二重購入をさせうる。**⚠ ただし**手元に状態がある**（`absent` 以外）
/// なら、問い合わせ中でもその値を出してよい —— 圏外で画面が空になるほうが困る。
@visibleForTesting
bool showEntitlementSection({
  required bool hasPreset,
  required EntitlementView view,
  required bool isRefreshing,
}) {
  if (hasPreset) return false;
  if (isRefreshing && view == EntitlementView.absent) return false;
  return true;
}

/// アカウント行の下に出すお知らせ通知 (#477) の UI 種別。
enum AnnouncementRowKind {
  /// 何も出さない。
  none,

  /// opt-in トグルを出す (購読対応プラットフォーム)。
  toggle,

  /// 「アプリ起動中しか届かない」旨の説明を出す (#919)。
  runningOnlyNote,
}

/// アカウント行に出すお知らせ通知の UI 種別を決める (#919)。
///
/// 判断材料が真偽値だけなので、画面から切り出してテスト可能にしてある
/// (desktop_menu_model.dart の #960 節と同じ流儀)。
///
/// - [platformSupported] … relay がそのプラットフォームへ配送するか
///   ([AnnouncementSubscriptionService.platformSupported])
/// - [serverSupported] … モロヘイヤが features.announcement_push を返すか
/// - [registered] … 親 push subscription が registered か (新規 enable の入口)
/// - [hasLocalState] … saved subscription / opt-out marker がローカルに在るか
///
/// トグルを [registered] だけで出すと、register snapshot が一時的に
/// idle / failed に落ちている間に「relay 側の subscription は active なのに
/// UI から OFF にできない」状態が生まれるため、[hasLocalState] でも出す
/// (Codex 指摘)。
///
/// 説明は**購読できないプラットフォームだけ**に出す。トグルが出る環境で
/// 「起動中のみ」と書くと嘘になるし、対応サーバーでない環境ではそもそも
/// お知らせ push の話題自体が無関係になる。
@visibleForTesting
AnnouncementRowKind resolveAnnouncementRow({
  required bool platformSupported,
  required bool serverSupported,
  required bool registered,
  required bool hasLocalState,
}) {
  if (!serverSupported) return AnnouncementRowKind.none;
  if (!platformSupported) return AnnouncementRowKind.runningOnlyNote;
  return (registered || hasLocalState)
      ? AnnouncementRowKind.toggle
      : AnnouncementRowKind.none;
}

class _AccountStatusTile extends ConsumerStatefulWidget {
  const _AccountStatusTile({
    required this.account,
    required this.snapshot,
    required this.hasPreset,
    required this.hasEntitlement,
  });

  final Account account;
  final PushRegistrationSnapshot? snapshot;
  final bool hasPreset;

  /// 手元に有償リレーの利用権トークンがあるか (#1218)。
  final bool hasEntitlement;

  @override
  ConsumerState<_AccountStatusTile> createState() => _AccountStatusTileState();
}

class _AccountStatusTileState extends ConsumerState<_AccountStatusTile> {
  bool _hasAnnouncementLocalState = false;

  @override
  void initState() {
    super.initState();
    _loadAnnouncementLocalState();
  }

  Future<void> _loadAnnouncementLocalState() async {
    final hasState = await AnnouncementSubscriptionService.hasLocalState(
      widget.account.key.toStorageKey(),
    );
    if (mounted && hasState != _hasAnnouncementLocalState) {
      setState(() => _hasAnnouncementLocalState = hasState);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final snapshot = widget.snapshot;
    final hasPreset = widget.hasPreset;
    final label = '@${account.key.username}@${account.key.host}';
    final state = snapshot?.state ?? PushRegistrationState.idle;
    // ⚠⚠ **判定はサービス側の 1 本を呼ぶ (#1218)。**ここに書き写すと、
    // 経路が増えたときに**サービス側だけ直って画面が取り残される** ——
    // 実際 #1181 で利用権の経路を足したときにそうなり、**買った人に
    // 「登録対象外」と出していた**（2026-10-04 の内部テストで実測）。
    final eligible = PushRegistrationService.shouldAttemptRegistration(
      host: account.key.host,
      eligible: hasPreset,
      hasEntitlement: widget.hasEntitlement,
    );

    final (
      statusText,
      statusColor,
      statusIcon,
    ) = describePushRegistrationStatus(
      Theme.of(context),
      state,
      eligible,
      snapshot?.reason,
    );

    // お知らせ通知 (#477 / #919)。判断は [resolveAnnouncementRow] に集約する。
    final announcementRow = resolveAnnouncementRow(
      platformSupported: AnnouncementSubscriptionService.platformSupported,
      serverSupported: account.mulukhiya?.announcementPushEnabled ?? false,
      registered: state == PushRegistrationState.registered,
      hasLocalState: _hasAnnouncementLocalState,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(statusIcon, color: statusColor),
          title: Text(label),
          subtitle: Text(
            [
              statusText,
              if (snapshot?.errorMessage != null) snapshot!.errorMessage!,
            ].join('\n'),
          ),
          isThreeLine: snapshot?.errorMessage != null,
          trailing: isPushRegistrationRetryable(state, eligible: eligible)
              ? TextButton(
                  onPressed: () => _retry(account),
                  child: const Text('再試行'),
                )
              : null,
        ),
        switch (announcementRow) {
          AnnouncementRowKind.none => const SizedBox.shrink(),
          AnnouncementRowKind.toggle => _AnnouncementToggle(account: account),
          AnnouncementRowKind.runningOnlyNote => const _RunningOnlyNote(),
        },
      ],
    );
  }

  void _retry(Account account) {
    // hasPreset は親 tile から props 経由で渡されているため再計算不要。
    PushRegistrationService.registerAccount(
      account,
      eligible: widget.hasPreset,
    );
  }
}

/// お知らせ push を購読できないプラットフォームで、トグルの代わりに出す説明
/// (#919)。
///
/// Linux ではお知らせが WebSocket 経路 (#569) からしか来ないので、アプリを
/// 終了している間のお知らせは通知に出ない。**黙って何も出さないと「お知らせ通知に
/// 対応していない」と読まれる**（Windows でトグルが見当たらないという報告が #919
/// の発端）ので、届く条件と取りこぼしの回収先を明示する。
///
/// ⚠ **Windows は #978 で購読側へ移ったのでここには来ない。**（`windows` が
/// [AnnouncementSubscriptionService.deliverableDeviceTypes] に入り、トグルが出る）。
/// 発端が Windows だったぶん誤読しやすいので、増やすときは
/// `deliverableDeviceTypes` との対応を先に確かめること。
class _RunningOnlyNote extends StatelessWidget {
  const _RunningOnlyNote();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'お知らせの通知はアプリの起動中のみ届きます。'
              '終了している間に投稿されたお知らせは、'
              '次に起動したときお知らせ画面で確認できます。',
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// お知らせ通知 (#477) の opt-in トグル。capsicum-relay#14 の
/// `POST/DELETE /announcement_subscriptions` を叩く。
/// SharedPreferences 経由の状態を初回 build で読み込み、ON/OFF 時に
/// relay 通信を行う間はスイッチを disabled 化する。
class _AnnouncementToggle extends StatefulWidget {
  const _AnnouncementToggle({required this.account});

  final Account account;

  @override
  State<_AnnouncementToggle> createState() => _AnnouncementToggleState();
}

class _AnnouncementToggleState extends State<_AnnouncementToggle> {
  bool? _enabled;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await AnnouncementSubscriptionService.isEnabled(
      widget.account.key.toStorageKey(),
    );
    if (mounted) setState(() => _enabled = enabled);
  }

  Future<void> _toggle(bool next) async {
    final accountKey = widget.account.key.toStorageKey();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (next) {
        await AnnouncementSubscriptionService.enable(widget.account);
      } else {
        // ユーザーが明示的に OFF にしたので opt-out marker を立て、
        // 以降の auto-enable で再 ON されないようにする。
        await AnnouncementSubscriptionService.disable(
          accountKey,
          host: widget.account.key.host,
          explicit: true,
        );
      }
      if (mounted) setState(() => _enabled = next);
    } catch (e) {
      if (mounted) {
        setState(() => _error = _shortMessage(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _shortMessage(Object e) {
    final text = e.toString();
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 0, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('お知らせ通知を受け取る', style: TextStyle(fontSize: 14)),
              ),
              if (_busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Switch(
                  value: enabled ?? false,
                  onChanged: enabled == null ? null : _toggle,
                ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _error!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../model/account.dart';
import '../../../provider/account_manager_provider.dart';
import '../../../provider/push_registration_status_provider.dart';
import '../../../service/announcement_subscription_service.dart';
import '../../../service/push_registration_service.dart';
import '../../../service/push_registration_status.dart';
import '../../widget/push_registration_status_section.dart';

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
    final hasPreset = PushRegistrationService.hasPresetAmong(accounts);

    return Scaffold(
      appBar: AppBar(
        title: const Text('プッシュ通知'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              hasPreset
                  ? 'プリセットサーバーのアカウントが登録されているため、'
                        'すべてのアカウントでプッシュ通知が利用できます。'
                        '登録に失敗した場合は、各アカウントの行から再試行できます。'
                  : 'プッシュ通知はプリセットサーバーのアカウントが '
                        '1 つ以上登録されている場合に利用できます。',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          ...accounts.map(
            (account) => _AccountStatusTile(
              account: account,
              snapshot: statusMap[account.key.toStorageKey()],
              hasPreset: hasPreset,
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountStatusTile extends ConsumerStatefulWidget {
  const _AccountStatusTile({
    required this.account,
    required this.snapshot,
    required this.hasPreset,
  });

  final Account account;
  final PushRegistrationSnapshot? snapshot;
  final bool hasPreset;

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
    // プリセットサーバー本体か、プリセットがあって「連れて登録」される側か
    final eligible =
        hasPreset || PushRegistrationService.isPresetServer(account.key.host);

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

    // お知らせ通知 (#477) は購読対応プラットフォーム (mobile のみ。relay は
    // macos に配送しないため macOS ではトグル自体を出さない) かつ
    // features.announcement_push: true のモロヘイヤが必須。そのうえで、
    // (a) 親 push subscription が registered (新規 enable 操作の入口) または
    // (b) ローカルに saved subscription / opt-out marker がある (relay 側
    // active subscription を OFF にする経路を保つ) なら表示する。
    // (b) は register snapshot が一時的に idle/failed でも、既存の subscription
    // で push が届き続ける状況で UI から OFF にできないと事故るため (Codex 指摘)。
    final announcementSupported =
        AnnouncementSubscriptionService.platformSupported &&
        (account.mulukhiya?.announcementPushEnabled ?? false) &&
        (state == PushRegistrationState.registered ||
            _hasAnnouncementLocalState);

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
          trailing: _isRetryable(state, eligible)
              ? TextButton(
                  onPressed: () => _retry(account),
                  child: const Text('再試行'),
                )
              : null,
        ),
        if (announcementSupported) _AnnouncementToggle(account: account),
      ],
    );
  }

  bool _isRetryable(PushRegistrationState state, bool eligible) {
    if (!eligible) return false;
    return state == PushRegistrationState.failed ||
        state == PushRegistrationState.idle ||
        state == PushRegistrationState.skipped;
  }

  void _retry(Account account) {
    // hasPreset は親 tile から props 経由で渡されているため再計算不要。
    PushRegistrationService.registerAccount(
      account,
      eligible: widget.hasPreset,
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

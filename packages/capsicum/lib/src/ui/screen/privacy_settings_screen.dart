import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/upstream_error_message.dart';
import '../util/launch_url_toast.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/retry_error_view.dart';

/// プライバシーとつながりやすさ (#1375)。
///
/// ⚠ 決めたこと（2026-11-09 pooza）:
/// - 置き場所はアカウントの設定。**承認制・おすすめへの掲載はプロフィール編集
///   から移した**（置き場を 1 か所に揃える）
/// - 範囲は API で変えられるもののうち、過去の投稿にさかのぼって効く設定と
///   チャットの設定を除いたもの全部
/// - 節は Web と同じ「つながりやすさ」「被検索性」「プライバシー」。被検索性を
///   特に重視する
/// - Mastodon の「検索エンジンからアクセスできるようにする」（`noindex`）は API で
///   変えられないので、**状態を出して Web の設定へ誘導する**（上流が API を
///   用意するまで待つ）
///
/// ⚠ **押したらその場で保存する。**失敗したら元の値に戻す（どれも 1 項目ずつ
/// 独立した設定で、まとめて保存する理由が無い）。
///
/// ⚠ **null の項目は出さない**（そのサーバー・SNS に無い）。版の番号では分岐しない。
class PrivacySettingsScreen extends ConsumerStatefulWidget {
  const PrivacySettingsScreen({super.key});

  @override
  ConsumerState<PrivacySettingsScreen> createState() =>
      _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends ConsumerState<PrivacySettingsScreen> {
  /// 開いたときのアカウント。⚠ 保存中に切り替えられても、開いたアカウントへ書く。
  Account? _account;
  PrivacySettingsSupport? _support;

  PrivacySettings? _settings;
  Object? _loadError;

  /// 保存中か。⚠ 1 つずつ送る（連打で順番が入れ替わらないように）。
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _account = ref.read(currentAccountProvider);
    final adapter = _account?.adapter;
    _support = adapter is PrivacySettingsSupport
        ? adapter as PrivacySettingsSupport
        : null;
    _load();
  }

  Future<void> _load() async {
    final support = _support;
    if (support == null) return;
    setState(() => _loadError = null);
    try {
      final settings = await support.getPrivacySettings();
      if (mounted) setState(() => _settings = settings);
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'privacy_settings.op',
        operation: 'load',
        error: e,
        stackTrace: st,
        account: _account,
      );
      if (mounted) setState(() => _loadError = e);
    }
  }

  /// [changes] を保存する。手元へ先に反映し、失敗したら戻す。
  Future<void> _update(PrivacySettings changes) async {
    final support = _support;
    final before = _settings;
    if (support == null || before == null || _saving) return;
    final account = _account;
    final accountManager = ref.read(accountManagerProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final reblogLabel = ref.read(reblogLabelProvider);
    setState(() {
      _saving = true;
      _settings = before.merge(changes);
    });
    try {
      final saved = await support.updatePrivacySettings(changes);
      if (mounted) setState(() => _settings = saved);
      // 承認制・おすすめへの掲載は手元の User にも載っている（プロフィールの
      // 鍵の印など）。取り直して差し替える。⚠ 失敗しても保存は済んでいるので、
      // ここでは知らせない。
      if (account != null &&
          (changes.locked != null || changes.discoverable != null)) {
        try {
          final me = await account.adapter.getMyself();
          accountManager.updateUserOf(account.key, me);
        } catch (_) {}
      }
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'privacy_settings.op',
        operation: 'save',
        error: e,
        stackTrace: st,
        account: account,
      );
      if (mounted) setState(() => _settings = before);
      // 上流が理由を返していれば添える。プロフィール編集にあった頃
      // （`profile_edit_screen.dart`・#1335）と同じ部品で組む。
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            upstreamFailureText('保存に失敗しました', e, reblogLabel: reblogLabel),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openWebSettings() async {
    final host = _account?.key.host;
    if (host == null) return;
    await launchUrlOrToast(context, Uri.https(host, '/settings/privacy'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('プライバシーとつながりやすさ')),
      body: BottomSafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    if (_support == null) {
      return const Center(child: Text('このアカウントでは使えません'));
    }
    final settings = _settings;
    if (settings == null) {
      if (_loadError != null) {
        return RetryErrorView(message: '設定を読み込めませんでした', onRetry: _load);
      }
      return const Center(child: CircularProgressIndicator());
    }
    return AbsorbPointer(
      absorbing: _saving,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: privacySettingsTiles(
          context,
          settings,
          onChanged: _update,
          onOpenWebSettings: _openWebSettings,
        ),
      ),
    );
  }
}

/// 画面の中身。⚠ 項目の出し分け（null は出さない）をテストで見るために切り出す。
@visibleForTesting
List<Widget> privacySettingsTiles(
  BuildContext context,
  PrivacySettings s, {
  required void Function(PrivacySettings changes) onChanged,
  required VoidCallback onOpenWebSettings,
}) {
  Widget toggle(
    bool? value,
    String title,
    String? subtitle,
    PrivacySettings Function(bool v) change,
  ) {
    if (value == null) return const SizedBox.shrink();
    return SwitchListTile(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      value: value,
      onChanged: (v) => onChanged(change(v)),
    );
  }

  Widget visibility(
    FollowListVisibility? value,
    String title,
    PrivacySettings Function(FollowListVisibility v) change,
  ) {
    if (value == null) return const SizedBox.shrink();
    return ListTile(
      title: Text(title),
      trailing: DropdownButton<FollowListVisibility>(
        value: value,
        onChanged: (v) {
          if (v != null && v != value) onChanged(change(v));
        },
        items: [
          for (final option in FollowListVisibility.values)
            DropdownMenuItem(
              value: option,
              child: Text(followListVisibilityLabel(option)),
            ),
        ],
      ),
    );
  }

  final connection = [
    toggle(
      s.locked,
      'フォローを承認制にする',
      'フォローされる前に、相手を確かめて承認します',
      (v) => PrivacySettings(locked: v),
    ),
    toggle(
      s.autoAcceptFollowed,
      'フォロー中の相手は自動で承認する',
      '承認制のとき、自分がフォローしている相手からのフォローは確かめずに承認します',
      (v) => PrivacySettings(autoAcceptFollowed: v),
    ),
    toggle(
      s.discoverable,
      'おすすめ・発見に載せる',
      'ほかの人へのおすすめや、アカウントの一覧に載ります',
      (v) => PrivacySettings(discoverable: v),
    ),
  ];

  final discoverability = [
    toggle(
      s.indexable,
      '公開投稿を検索できるようにする',
      '公開の投稿が、このサーバーやほかのサーバーの検索に出ます',
      (v) => PrivacySettings(indexable: v),
    ),
    if (s.searchEngineHidden != null)
      s.searchEngineEditable
          ? toggle(
              // ⚠ Misskey の `noCrawle` は「載せない」側（Web の文言も
              // 「クローラーによるインデックスを拒否」で否定形）。画面は
              // Mastodon の項目と向きをそろえて「載せる」で聞くので反転する。
              !s.searchEngineHidden!,
              '検索エンジンに載せる',
              'Google などの検索エンジンが、プロフィールや投稿を拾えるようにします',
              (v) => PrivacySettings(searchEngineHidden: !v),
            )
          : ListTile(
              title: const Text('検索エンジンからアクセスできるようにする'),
              subtitle: Text(
                '${s.searchEngineHidden! ? 'いまは「しない」です' : 'いまは「する」です'}。'
                'このサーバーでは、アプリからは変えられません。Web の設定で変えられます',
              ),
              trailing: const Icon(Icons.open_in_new),
              onTap: onOpenWebSettings,
            ),
  ];

  final privacy = [
    toggle(
      s.hideCollections,
      'フォロー・フォロワーを隠す',
      'プロフィールで、フォロー中とフォロワーの一覧を見せません',
      (v) => PrivacySettings(hideCollections: v),
    ),
    visibility(
      s.followingVisibility,
      'フォロー中の一覧の公開範囲',
      (v) => PrivacySettings(followingVisibility: v),
    ),
    visibility(
      s.followersVisibility,
      'フォロワーの一覧の公開範囲',
      (v) => PrivacySettings(followersVisibility: v),
    ),
    toggle(
      s.publicReactions,
      'リアクションを公開する',
      '自分が付けたリアクションの一覧を、ほかの人も見られます',
      (v) => PrivacySettings(publicReactions: v),
    ),
    toggle(
      s.hideOnlineStatus,
      'オンライン状態を隠す',
      null,
      (v) => PrivacySettings(hideOnlineStatus: v),
    ),
    toggle(
      s.preventAiLearning,
      'AI の学習を拒否する',
      '投稿した画像などを、生成 AI の学習に使わないよう求めます',
      (v) => PrivacySettings(preventAiLearning: v),
    ),
    toggle(
      s.requireSigninToViewContents,
      'ログインしていない人には見せない',
      'プロフィールや投稿を見るのに、このサーバーへのログインを求めます',
      (v) => PrivacySettings(requireSigninToViewContents: v),
    ),
  ];

  bool shown(Widget w) => w is! SizedBox;
  return [
    for (final (label, tiles) in [
      ('つながりやすさ', connection),
      ('被検索性', discoverability),
      ('プライバシー', privacy),
    ])
      if (tiles.any(shown)) ...[_Header(label), ...tiles.where(shown)],
  ];
}

/// フォロー・フォロワーの一覧の公開範囲の表示名。
String followListVisibilityLabel(FollowListVisibility v) => switch (v) {
  FollowListVisibility.public => '公開',
  FollowListVisibility.followers => 'フォロワーのみ',
  FollowListVisibility.private => '自分のみ',
};

class _Header extends StatelessWidget {
  const _Header(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      label,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

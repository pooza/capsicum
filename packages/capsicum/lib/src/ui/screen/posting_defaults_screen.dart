import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../util/compose_settings_display.dart';
import '../util/post_scope_display.dart';
import '../widget/bottom_safe_area.dart';

/// サーバー側の投稿の既定 (#1210・Mastodon)。
///
/// 公開範囲・閲覧注意・言語・引用の許可。**投稿フォームは新規の投稿を開くとき
/// これを読んで使う**（#1185 / #1194）ので、端末側に別の既定は無い。保存すると
/// 次に開く投稿フォームから効き、Web など他のクライアントにも同じ値が出る。
///
/// ⚠ 置き場所（2026-10-18 pooza 判断）: 設定の一覧の「投稿の既定」。
class PostingDefaultsScreen extends ConsumerStatefulWidget {
  const PostingDefaultsScreen({super.key});

  @override
  ConsumerState<PostingDefaultsScreen> createState() =>
      _PostingDefaultsScreenState();
}

/// Mastodon が既定にできる公開範囲（`UserSettings` の `default_privacy`）。
/// ⚠ DM は既定にできない。
const _scopes = [PostScope.public, PostScope.unlisted, PostScope.followersOnly];

/// 言語を「指定しない」（端末・Web の表示言語に任せる）の値。上流は空文字で外す。
const _noLanguage = '';

class _PostingDefaultsScreenState extends ConsumerState<PostingDefaultsScreen> {
  late PostScope _scope;
  late bool _sensitive;
  late String _language;
  String? _quotePolicy;
  bool _saving = false;

  /// 開いたときのアカウント。⚠ 保存中に切り替えられても、開いたアカウントへ書く。
  Account? _account;
  PostingDefaultsSupport? _support;

  @override
  void initState() {
    super.initState();
    _account = ref.read(currentAccountProvider);
    final adapter = _account?.adapter;
    _support = adapter is PostingDefaultsSupport
        ? adapter as PostingDefaultsSupport
        : null;
    final user = _account?.user;
    final scope = user?.defaultScope;
    _scope = scope != null && _scopes.contains(scope)
        ? scope
        : PostScope.public;
    _sensitive = user?.defaultSensitive ?? false;
    _language = user?.defaultLanguage ?? _noLanguage;
    // ⚠ 引用の許可は、サーバーが返したときだけ出す（4.5 より前は無い）。
    final policy = user?.defaultQuotePolicy;
    _quotePolicy = policy != null && quoteApprovalLabels.containsKey(policy)
        ? policy
        : null;
  }

  Future<void> _save() async {
    final support = _support;
    if (support == null || _saving) return;
    final account = _account;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final accountManager = ref.read(accountManagerProvider.notifier);
    setState(() => _saving = true);
    try {
      final user = await support.updatePostingDefaults(
        scope: _scope,
        sensitive: _sensitive,
        language: _language,
        quotePolicy: _quotePolicy,
      );
      // ⚠ 開いたアカウントがまだ現在のアカウントなら、手元の `User` を差し替える。
      // 差し替えないと、次の取り直し（#1185 の TTL）まで投稿フォームが古い既定で
      // 開く。
      if (ref.exists(currentAccountProvider) &&
          ref.read(currentAccountProvider)?.key == account?.key) {
        accountManager.updateCurrentUser(user);
      }
      if (!mounted) return;
      navigator.maybePop();
      messenger.showSnackBar(
        const SnackBar(content: Text('保存しました。次に開く投稿から効きます')),
      );
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'posting_defaults.op',
        operation: 'save',
        error: e,
        stackTrace: st,
        account: account,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(const SnackBar(content: Text('保存に失敗しました')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final adapter = _account?.adapter;
    final languages = {
      _noLanguage: '指定しない（表示の言語に合わせる）',
      ...composeLanguageOptions,
      // ⚠ 9 言語の外（`it` など）も保存されうる。選択肢に無い値を渡すと
      // DropdownButton が壊れるので、現在値は必ず含める（投稿画面と同じ守り）。
      if (_language != _noLanguage &&
          !composeLanguageOptions.containsKey(_language))
        _language: _language,
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('投稿の既定'),
        actions: [
          if (_support != null)
            TextButton(
              onPressed: _saving ? null : _save,
              child: const Text('保存'),
            ),
        ],
      ),
      body: BottomSafeArea(
        child: _support == null
            ? const Center(child: Text('このアカウントでは使えません'))
            : AbsorbPointer(
                absorbing: _saving,
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Text(
                        'サーバーに保存される、新しい投稿の既定です。Web など'
                        'ほかのアプリにも同じ値が出ます。投稿ごとに変えたいときは、'
                        '投稿画面で選べます。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    const _Header('公開範囲'),
                    RadioGroup<PostScope>(
                      groupValue: _scope,
                      onChanged: (value) {
                        if (value != null) setState(() => _scope = value);
                      },
                      child: Column(
                        children: [
                          for (final scope in _scopes)
                            RadioListTile<PostScope>(
                              value: scope,
                              secondary: Icon(postScopeIcon(scope, adapter)),
                              title: Text(postScopeLabel(scope, adapter)),
                            ),
                        ],
                      ),
                    ),
                    const _Header('閲覧注意'),
                    SwitchListTile(
                      title: const Text('メディアを常に閲覧注意にする'),
                      value: _sensitive,
                      onChanged: (value) => setState(() => _sensitive = value),
                    ),
                    const _Header('言語'),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: _language,
                        items: [
                          for (final entry in languages.entries)
                            DropdownMenuItem(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) setState(() => _language = value);
                        },
                      ),
                    ),
                    if (_quotePolicy != null) ...[
                      const _Header('引用の許可'),
                      RadioGroup<String>(
                        groupValue: _quotePolicy,
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _quotePolicy = value);
                          }
                        },
                        child: Column(
                          children: [
                            for (final entry in quoteApprovalLabels.entries)
                              RadioListTile<String>(
                                value: entry.key,
                                title: Text(entry.value),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}

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

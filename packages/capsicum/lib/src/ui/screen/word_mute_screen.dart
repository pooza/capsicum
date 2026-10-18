import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/misskey_api_error.dart';
import '../widget/bottom_safe_area.dart';

/// Misskey のワードミュート (#1290)。
///
/// 本家の設定（「ミュートとブロック」の中）と同じく **「ワードミュート」と
/// 「ハードワードミュート」の 2 段**で、入力の規則も本家どおり（1 行 1 条件・
/// 半角スペース区切りが AND・`/…/flags` が正規表現）。設計は
/// `docs/filter-management-plan.md` 決定済み事項 6。
class WordMuteScreen extends ConsumerStatefulWidget {
  const WordMuteScreen({super.key});

  @override
  ConsumerState<WordMuteScreen> createState() => _WordMuteScreenState();
}

class _WordMuteScreenState extends ConsumerState<WordMuteScreen> {
  final _soft = TextEditingController();
  final _hard = TextEditingController();
  String _savedSoft = '';
  String _savedHard = '';

  /// 読み込んだときの一覧。⚠ 保存のとき、触っていない行は元の要素のまま送る
  /// （[parseWordMuteText] の `original`・#1293）。
  List<Object> _loadedSoft = const [];
  List<Object> _loadedHard = const [];
  bool _loading = true;
  bool _loadFailed = false;
  bool _saving = false;

  /// 読み込んだときのアカウント。⚠ 切り替えたら読み直し、別のアカウントへ
  /// 書き込まない。
  String? _loadedFor;
  bool _initialized = false;
  WordMuteSupport? _support;
  Account? _account;

  @override
  void dispose() {
    _soft.dispose();
    _hard.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final support = _support;
    if (support == null) return;
    final loadingFor = _loadedFor;
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final mutes = await support.getWordMutes();
      if (!mounted || loadingFor != _loadedFor) return;
      _loadedSoft = mutes.soft;
      _loadedHard = mutes.hard;
      _savedSoft = formatWordMuteText(mutes.soft);
      _savedHard = formatWordMuteText(mutes.hard);
      _soft.text = _savedSoft;
      _hard.text = _savedHard;
      setState(() => _loading = false);
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'word_mute.list',
        operation: 'load',
        error: e,
        stackTrace: st,
        account: _account,
      );
      if (!mounted || loadingFor != _loadedFor) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _save() async {
    final support = _support;
    if (support == null || _saving) return;
    // ⚠ 失敗の記録に使うアカウントは、保存を始めた時点で取る。await のあいだに
    // アカウントを切り替えられると、`_account` は切替後になる (#1293)。
    final account = _account;
    final messenger = ScaffoldMessenger.of(context);
    final softChanged = _soft.text != _savedSoft;
    final hardChanged = _hard.text != _savedHard;
    if (!softChanged && !hardChanged) {
      Navigator.of(context).maybePop();
      return;
    }
    final soft = parseWordMuteText(_soft.text, original: _loadedSoft);
    final hard = parseWordMuteText(_hard.text, original: _loadedHard);
    final invalid = soft.invalidLine != null
        ? 'ワードミュートの ${soft.invalidLine} 行目の正規表現が読めません'
        : hard.invalidLine != null
        ? 'ハードワードミュートの ${hard.invalidLine} 行目の正規表現が読めません'
        : null;
    if (invalid != null) {
      messenger.showSnackBar(SnackBar(content: Text(invalid)));
      return;
    }
    setState(() => _saving = true);
    try {
      await support.setWordMutes(
        soft: softChanged ? soft.entries : null,
        hard: hardChanged ? hard.entries : null,
      );
      if (!mounted) return;
      Navigator.of(context).maybePop();
      messenger.showSnackBar(
        const SnackBar(content: Text('保存しました。次に読み込んだ投稿から効きます')),
      );
    } catch (e, st) {
      // ⚠ 入力が原因の既知のエラーは送らない（理由は SnackBar に出す・#1047 の
      // リリース前レビュー）。
      final reason = _saveFailureReason(e);
      if (reason == null) {
        reportOpFailure(
          tagKey: 'word_mute.op',
          operation: 'save',
          error: e,
          stackTrace: st,
          account: account,
        );
      }
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(content: Text(reason ?? 'ワードミュートの保存に失敗しました')),
      );
    }
  }

  /// 入力が原因で弾かれたときの理由。それ以外の失敗は null。
  static String? _saveFailureReason(Object error) =>
      switch (misskeyApiErrorCode(error)) {
        'TOO_MANY_MUTED_WORDS' => '保存に失敗しました: 語句が多すぎます（文字数の合計の上限を超えています）',
        'INVALID_REGEXP' => '保存に失敗しました: サーバーが読めない正規表現があります',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final adapter = ref.watch(currentAdapterProvider);
    final accountKey = ref.watch(currentAccountProvider)?.key.toStorageKey();
    if (!_initialized || _loadedFor != accountKey) {
      _initialized = true;
      _loadedFor = accountKey;
      _support = adapter is WordMuteSupport ? adapter as WordMuteSupport : null;
      _account = ref.read(currentAccountProvider);
      // ⚠ 読み込みは次のフレームで始まるので、ここで読み込み中にしておく。
      // しないと切替直後の 1 フレームだけ、前のアカウントの文面のまま保存
      // ボタンが出る (#1293)。build の中なので setState は要らない。
      _loading = true;
      _loadFailed = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ワードミュート'),
        actions: [
          if (_support != null && !_loading && !_loadFailed)
            TextButton(
              onPressed: _saving ? null : _save,
              child: const Text('保存'),
            ),
        ],
      ),
      body: BottomSafeArea(
        child: _support == null
            ? const Center(child: Text('このアカウントではワードミュートを使えません'))
            : _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadFailed
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('読み込みに失敗しました'),
                    const SizedBox(height: 8),
                    TextButton(onPressed: _load, child: const Text('再読み込み')),
                  ],
                ),
              )
            : AbsorbPointer(
                absorbing: _saving,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      '1 行に 1 つずつ書きます。半角スペースで区切ると、その語を'
                      'すべて含む投稿に当たります。/ で囲むと正規表現になります'
                      '（例: /ダイ(の|大)冒険/）。大文字と小文字は区別します。',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    _section(
                      theme,
                      title: 'ワードミュート',
                      description: '指定した語句を含む投稿を畳みます。タップすると読めます。',
                      controller: _soft,
                      loaded: _loadedSoft,
                    ),
                    const SizedBox(height: 24),
                    _section(
                      theme,
                      title: 'ハードワードミュート',
                      description: '指定した語句を含む投稿を、一覧から消します。',
                      controller: _hard,
                      loaded: _loadedHard,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '保存した内容は、次に読み込んだ投稿から効きます。',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _section(
    ThemeData theme, {
    required String title,
    required String description,
    required TextEditingController controller,
    required List<Object> loaded,
  }) {
    // ⚠ サーバーと Web では効くが、capsicum の判定からは外れる行 (#1293)。
    // 黙って外れると「capsicum でだけ伏せられない」理由が分からないので出す。
    final unreadable = [
      for (final line in unreadableWordMuteLines(loaded)) loaded[line - 1],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 4),
        Text(description, style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          minLines: 4,
          maxLines: 12,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: title,
          ),
        ),
        if (unreadable.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '次の正規表現は capsicum では判定に使えません（サーバーと Web では効きます）: '
            '${unreadable.join('、')}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

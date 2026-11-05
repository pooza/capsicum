import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../util/antenna_text.dart';
import '../util/op_error.dart';
import '../widget/bottom_safe_area.dart';

/// 「対象」の選択肢の呼び名 (#1052)。
@visibleForTesting
String antennaSourceLabel(AntennaSource source) => switch (source) {
  AntennaSource.all => 'すべての投稿',
  AntennaSource.users => '指定したユーザーの投稿',
  AntennaSource.usersBlacklist => '指定したユーザーを除いたすべての投稿',
  AntennaSource.home => 'ホームの投稿',
  AntennaSource.list => 'リストのユーザーの投稿',
};

/// 「対象」に出す選択肢 (#1052)。
///
/// ⚠ Misskey Web と同じく、ホームとリストは出さない（Web は選択肢から外して
/// いる）。⚠ ただし今そうなっているアンテナを開いたときは、その値を残す
/// （出さないと、開いて保存しただけで別の対象に変わる）。
@visibleForTesting
List<AntennaSource> antennaSourceChoices(AntennaSource current) => [
  AntennaSource.all,
  AntennaSource.users,
  AntennaSource.usersBlacklist,
  if (current == AntennaSource.home || current == AntennaSource.list) current,
];

/// アンテナの作成 / 編集 (#1052)。[antenna] が null なら作成。
///
/// 項目は Misskey Web の編集画面と同じに揃える（`MkAntennaEditor.vue`）。
/// 保存できたら `true` を返して閉じる（一覧が取り直す）。失敗したら入力を残して
/// 留まる（`docs/product-policy.md`「閲覧のみの族の型」）。
class AntennaEditScreen extends ConsumerStatefulWidget {
  const AntennaEditScreen({super.key, this.antenna});

  final Antenna? antenna;

  @override
  ConsumerState<AntennaEditScreen> createState() => _AntennaEditScreenState();
}

class _AntennaEditScreenState extends ConsumerState<AntennaEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _users;
  late final TextEditingController _keywords;
  late final TextEditingController _excludeKeywords;
  late AntennaSource _source;
  String? _userListId;
  late bool _caseSensitive;
  late bool _localOnly;
  late bool _excludeBots;
  late bool _withReplies;
  late bool _withFile;
  late bool _excludeNotesInSensitiveChannel;
  bool _saving = false;

  /// 編集を始めたときのアカウント。⚠ 保存中にアカウントを切り替えられても、
  /// 始めたアカウントのアダプターで保存する（別アカウントへ書き込まない）。
  AntennaManagementSupport? _support;
  Account? _account;

  bool get _isNew => widget.antenna == null;

  @override
  void initState() {
    super.initState();
    final antenna = widget.antenna;
    final c = antenna?.conditions ?? const AntennaDraft(name: '');
    _name = TextEditingController(text: antenna?.name ?? '');
    _users = TextEditingController(text: antennaUsersToText(c.users));
    _keywords = TextEditingController(text: antennaKeywordsToText(c.keywords));
    _excludeKeywords = TextEditingController(
      text: antennaKeywordsToText(c.excludeKeywords),
    );
    _source = c.source;
    _userListId = c.userListId;
    _caseSensitive = c.caseSensitive;
    _localOnly = c.localOnly;
    _excludeBots = c.excludeBots;
    _withReplies = c.withReplies;
    _withFile = c.withFile;
    _excludeNotesInSensitiveChannel = c.excludeNotesInSensitiveChannel;
    final adapter = ref.read(currentAdapterProvider);
    _support = adapter is AntennaManagementSupport
        ? adapter as AntennaManagementSupport
        : null;
    _account = ref.read(currentAccountProvider);
  }

  @override
  void dispose() {
    _name.dispose();
    _users.dispose();
    _keywords.dispose();
    _excludeKeywords.dispose();
    super.dispose();
  }

  bool get _usesUsers =>
      _source == AntennaSource.users || _source == AntennaSource.usersBlacklist;

  Future<void> _save() async {
    final support = _support;
    if (support == null || _saving) return;
    final messenger = ScaffoldMessenger.of(context);
    final name = _name.text.trim();
    if (name.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('名前を入れてください')));
      return;
    }
    final keywords = antennaKeywordsFromText(_keywords.text);
    final excludeKeywords = antennaKeywordsFromText(_excludeKeywords.text);
    // ⚠ サーバーは両方とも空なら断る（`EMPTY_KEYWORD`）。送る前に知らせる。
    if (keywords.isEmpty && excludeKeywords.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('キーワードか除外キーワードを入れてください')),
      );
      return;
    }
    final draft = AntennaDraft(
      name: name,
      source: _source,
      userListId: _userListId,
      keywords: keywords,
      excludeKeywords: excludeKeywords,
      // ⚠ 対象がユーザーでないときも、入力は消さずに送る（Web と同じ）。
      users: antennaUsersFromText(_users.text),
      caseSensitive: _caseSensitive,
      localOnly: _localOnly,
      excludeBots: _excludeBots,
      withReplies: _withReplies,
      withFile: _withFile,
      excludeNotesInSensitiveChannel: _excludeNotesInSensitiveChannel,
    );
    setState(() => _saving = true);
    try {
      if (_isNew) {
        await support.createAntenna(draft);
      } else {
        await support.updateAntenna(widget.antenna!.id, draft);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AntennaLimitReached {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('このアカウントでは、これ以上アンテナを作れません')),
      );
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'antenna.op',
        operation: _isNew ? 'create' : 'update',
        error: e,
        stackTrace: st,
        account: _account,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(content: Text('アンテナの保存に失敗しました\n${summarizeOpError(e)}')),
      );
    }
  }

  Widget _switch(String title, bool value, ValueChanged<bool> onChanged) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        value: value,
        onChanged: (v) => setState(() => onChanged(v)),
      );

  @override
  Widget build(BuildContext context) {
    const keywordHelp = '改行で区切ると「または」、半角スペースで区切ると「かつ」になります';
    // ⚠ 保存中に戻ると結果を一覧へ渡せず、作れていないように見えて作り直される。
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          // ⚠ [PopScope] が止めているので、押せるように見せない。
          leading: _saving
              ? const IconButton(
                  onPressed: null,
                  tooltip: '保存中は戻れません',
                  icon: BackButtonIcon(),
                )
              : null,
          bottom: _saving
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(4),
                  child: LinearProgressIndicator(),
                )
              : null,
          title: Text(_isNew ? 'アンテナを作成' : 'アンテナを編集'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          actions: [
            TextButton(
              onPressed: _saving ? null : _save,
              child: const Text('保存'),
            ),
          ],
        ),
        body: BottomSafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _name,
                maxLength: 100,
                decoration: const InputDecoration(labelText: '名前'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<AntennaSource>(
                initialValue: _source,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '対象'),
                items: [
                  for (final source in antennaSourceChoices(
                    widget.antenna?.conditions?.source ?? AntennaSource.all,
                  ))
                    DropdownMenuItem(
                      value: source,
                      child: Text(antennaSourceLabel(source)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _source = value);
                },
              ),
              if (_usesUsers) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _users,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'ユーザー',
                    helperText: '1 行に 1 人（@user または @user@host）',
                  ),
                ),
              ],
              _switch('Bot を除く', _excludeBots, (v) => _excludeBots = v),
              _switch('返信を含める', _withReplies, (v) => _withReplies = v),
              const SizedBox(height: 8),
              TextField(
                controller: _keywords,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'キーワード',
                  helperText: keywordHelp,
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _excludeKeywords,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '除外キーワード',
                  helperText: keywordHelp,
                  helperMaxLines: 2,
                ),
              ),
              _switch('ローカルのみ', _localOnly, (v) => _localOnly = v),
              _switch(
                '大文字と小文字を区別する',
                _caseSensitive,
                (v) => _caseSensitive = v,
              ),
              _switch('ファイルが添付された投稿のみ', _withFile, (v) => _withFile = v),
              _switch(
                'センシティブなチャンネルの投稿を除く',
                _excludeNotesInSensitiveChannel,
                (v) => _excludeNotesInSensitiveChannel = v,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

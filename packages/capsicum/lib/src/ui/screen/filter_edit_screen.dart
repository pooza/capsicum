import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/upstream_error_message.dart';
import '../util/filter_labels.dart';
import '../widget/bottom_safe_area.dart';

/// フィルターの作成 / 編集 (#1047)。[filter] が null なら作成。
///
/// 保存できたら `true` を返して閉じる（一覧が取り直す）。設計は
/// `docs/filter-management-plan.md` 決定済み事項 5。
class FilterEditScreen extends ConsumerStatefulWidget {
  const FilterEditScreen({super.key, this.filter});

  final ServerFilter? filter;

  @override
  ConsumerState<FilterEditScreen> createState() => _FilterEditScreenState();
}

class _KeywordRow {
  _KeywordRow({this.id, String text = '', this.wholeWord = true})
    : controller = TextEditingController(text: text);

  final String? id;
  final TextEditingController controller;
  bool wholeWord;
}

class _FilterEditScreenState extends ConsumerState<FilterEditScreen> {
  late final TextEditingController _title;
  late final List<_KeywordRow> _keywords;
  final _removedKeywordIds = <String>[];
  late Set<FilterContext> _contexts;
  late FilterAction _action;

  /// [filterExpiryChoices] の添字。⚠ **-1 は「変えない」**（編集で期限が付いて
  /// いるときだけ選べる）。
  late int _expiryIndex;
  bool _saving = false;

  /// 編集を始めたときのアカウント。⚠ 保存中にアカウントを切り替えられても、
  /// 始めたアカウントのアダプターで保存する（別アカウントへ書き込まない）。
  FilterSupport? _support;
  Account? _account;

  bool get _isNew => widget.filter == null;

  @override
  void initState() {
    super.initState();
    final filter = widget.filter;
    _title = TextEditingController(text: filter?.title ?? '');
    _keywords = [
      for (final k in filter?.keywords ?? const <FilterKeyword>[])
        _KeywordRow(id: k.id, text: k.keyword, wholeWord: k.wholeWord),
    ];
    if (_keywords.isEmpty) _keywords.add(_KeywordRow());
    // 新規の適用先は Mastodon Web の既定と同じくホーム・通知・公開・会話。
    _contexts =
        filter?.contexts.toSet() ??
        {
          FilterContext.home,
          FilterContext.notifications,
          FilterContext.public,
          FilterContext.thread,
        };
    _action = filter?.action ?? FilterAction.warn;
    _expiryIndex = filter?.expiresAt != null ? -1 : 0;
    final adapter = ref.read(currentAdapterProvider);
    _support = adapter is FilterSupport ? adapter as FilterSupport : null;
    _account = ref.read(currentAccountProvider);
  }

  @override
  void dispose() {
    _title.dispose();
    for (final row in _keywords) {
      row.controller.dispose();
    }
    super.dispose();
  }

  FilterDraft _draft() {
    final keywords = <FilterKeyword>[];
    final removed = [..._removedKeywordIds];
    for (final row in _keywords) {
      final text = row.controller.text.trim();
      if (text.isEmpty) {
        // 既存のキーワードを空にしたら消す扱い。新規の空行は送らない。
        if (row.id != null) removed.add(row.id!);
        continue;
      }
      keywords.add(
        FilterKeyword(id: row.id, keyword: text, wholeWord: row.wholeWord),
      );
    }
    return FilterDraft(
      title: _title.text.trim(),
      contexts: _contexts,
      action: _action,
      expiry: switch (_expiryIndex) {
        -1 => const KeepFilterExpiry(),
        _ => switch (filterExpiryChoices[_expiryIndex].$2) {
          null => const NoFilterExpiry(),
          final duration => FilterExpiresIn(duration),
        },
      },
      keywords: keywords,
      removedKeywordIds: removed,
    );
  }

  String? _validate(FilterDraft draft) {
    if (draft.title.isEmpty) return '名前を入れてください';
    if (draft.contexts.isEmpty) return '適用先を 1 つ以上選んでください';
    if (draft.keywords.isEmpty) return 'キーワードを 1 つ以上入れてください';
    return null;
  }

  Future<void> _save() async {
    final support = _support;
    if (support == null || _saving) return;
    final draft = _draft();
    final messenger = ScaffoldMessenger.of(context);
    final invalid = _validate(draft);
    if (invalid != null) {
      messenger.showSnackBar(SnackBar(content: Text(invalid)));
      return;
    }
    final reblogLabel = ref.read(reblogLabelProvider);
    setState(() => _saving = true);
    try {
      if (_isNew) {
        await support.createFilter(draft);
      } else {
        await support.updateFilter(widget.filter!.id, draft);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'filter.op',
        operation: _isNew ? 'create' : 'update',
        error: e,
        stackTrace: st,
        account: _account,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      // ⚠ Mastodon の 422 は人間向けの文で返る（「メディアをぼかす」を知らない
      // 古い版など）。版で分岐せず、理由をそのまま添える。
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            upstreamFailureText('フィルターの保存に失敗しました', e, reblogLabel: reblogLabel),
          ),
        ),
      );
    }
  }

  Future<void> _delete() async {
    final support = _support;
    final filter = widget.filter;
    if (support == null || filter == null || _saving) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('フィルターを削除'),
        content: Text('「${filter.title}」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await support.deleteFilter(filter.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'filter.op',
        operation: 'delete',
        error: e,
        stackTrace: st,
        account: _account,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(const SnackBar(content: Text('フィルターの削除に失敗しました')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final existingExpiry = widget.filter?.expiresAt;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'フィルターを作成' : 'フィルターを編集'),
        actions: [
          if (!_isNew)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '削除',
              onPressed: _saving ? null : _delete,
            ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: BottomSafeArea(
        child: AbsorbPointer(
          absorbing: _saving,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _title,
                  decoration: const InputDecoration(labelText: '名前'),
                  maxLength: 256,
                ),
              ),
              _SectionHeader('キーワード'),
              for (final row in _keywords) _keywordTile(row),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('キーワードを追加'),
                  onPressed: () => setState(() => _keywords.add(_KeywordRow())),
                ),
              ),
              _SectionHeader('適用先'),
              for (final context in FilterContext.values)
                CheckboxListTile(
                  value: _contexts.contains(context),
                  title: Text(filterContextLabel(context)),
                  subtitle: Text(filterContextHint(context)),
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      _contexts.add(context);
                    } else {
                      _contexts.remove(context);
                    }
                  }),
                ),
              _SectionHeader('フィルターの動作'),
              RadioGroup<FilterAction>(
                groupValue: _action,
                onChanged: (value) {
                  if (value != null) setState(() => _action = value);
                },
                child: Column(
                  children: [
                    for (final action in FilterAction.values)
                      RadioListTile<FilterAction>(
                        value: action,
                        title: Text(filterActionLabel(action)),
                        subtitle: Text(filterActionHint(action)),
                      ),
                  ],
                ),
              ),
              _SectionHeader('有効期限'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: _expiryIndex,
                  items: [
                    if (existingExpiry != null)
                      DropdownMenuItem(
                        value: -1,
                        child: Text(
                          '変えない（${_formatExpiry(existingExpiry.toLocal())} まで）',
                        ),
                      ),
                    for (var i = 0; i < filterExpiryChoices.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(filterExpiryChoices[i].$1),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _expiryIndex = value);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  '保存した内容は、次に読み込んだ投稿から効きます。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _keywordTile(_KeywordRow row) => Padding(
    padding: const EdgeInsets.only(left: 16, right: 4),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: row.controller,
            decoration: const InputDecoration(hintText: 'キーワード'),
            maxLength: 512,
          ),
        ),
        const SizedBox(width: 8),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: row.wholeWord,
              onChanged: (value) =>
                  setState(() => row.wholeWord = value ?? true),
            ),
            Text('単語全体', style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
        IconButton(
          icon: const Icon(Icons.remove_circle_outline),
          tooltip: 'このキーワードを外す',
          onPressed: () => setState(() {
            _keywords.remove(row);
            if (row.id != null) _removedKeywordIds.add(row.id!);
            row.controller.dispose();
            if (_keywords.isEmpty) _keywords.add(_KeywordRow());
          }),
        ),
      ],
    ),
  );

  static String _formatExpiry(DateTime at) =>
      '${at.month}/${at.day} ${at.hour}:${at.minute.toString().padLeft(2, '0')}';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

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

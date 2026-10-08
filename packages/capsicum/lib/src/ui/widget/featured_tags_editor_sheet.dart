import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../util/exception_scrub.dart';
import '../../util/upstream_error_message.dart';

/// 入力をタグ名に均す (#1075)。先頭の `#` と前後の空白を落とす。
///
/// 空・空白を含むものは null（タグにならない）。それ以外の書式はサーバーの判定
/// （`Tag::HASHTAG_NAME_RE`）に任せる。⚠ 手元で書式を真似ると、サーバーが通す
/// 名前（`・` を挟むもの等）を弾く側にずれうる。
String? normalizeFeaturedTagInput(String input) {
  final name = input.trim().replaceFirst(RegExp(r'^#+'), '').trim();
  if (name.isEmpty || RegExp(r'\s').hasMatch(name)) return null;
  return name;
}

/// 自分のプロフィールで紹介するハッシュタグを編集するシート (#1075)。
///
/// ⚠ **デッキのカラムから開いても、そのカラムのアカウントで動く**（シートは
/// `ProviderScopeCarrier` が開く側のスコープを持ち込む・#1149）。
///
/// 変更のたびに [onChanged] で最新の一覧を返す（プロフィールの表示を追従させる）。
class FeaturedTagsEditorSheet extends ConsumerStatefulWidget {
  const FeaturedTagsEditorSheet({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  final List<FeaturedTag> initial;
  final ValueChanged<List<FeaturedTag>> onChanged;

  @override
  ConsumerState<FeaturedTagsEditorSheet> createState() =>
      _FeaturedTagsEditorSheetState();
}

class _FeaturedTagsEditorSheetState
    extends ConsumerState<FeaturedTagsEditorSheet> {
  late List<FeaturedTag> _tags = List.of(widget.initial);
  List<String> _suggestions = const [];
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  FeaturedTagSupport? get _adapter =>
      switch (ref.read(currentAdapterProvider)) {
        final FeaturedTagSupport a => a,
        _ => null,
      };

  bool get _full => _tags.length >= featuredTagLimit;

  @override
  void initState() {
    super.initState();
    _loadSuggestions();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadSuggestions() async {
    try {
      final names = await _adapter?.getFeaturedTagSuggestions() ?? const [];
      if (mounted) setState(() => _suggestions = names);
    } catch (_) {
      // 候補は補助なので、取れなければ出さない。
    }
  }

  bool _alreadyFeatured(String name) =>
      _tags.any((t) => t.name.toLowerCase() == name.toLowerCase());

  Future<void> _add(String input) async {
    final adapter = _adapter;
    final name = normalizeFeaturedTagInput(input);
    if (adapter == null || _busy) return;
    if (name == null) {
      setState(() => _error = 'タグ名を入力してください（空白は使えません）');
      return;
    }
    if (_alreadyFeatured(name)) {
      setState(() => _error = '#$name はすでに紹介しています');
      return;
    }
    if (_full) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final tag = await adapter.featureTag(name);
      if (!mounted) return;
      setState(() {
        // 掲載済みを渡すとサーバーは既存を返すので、ID で重複を避ける。
        if (!_tags.any((t) => t.id == tag.id)) _tags = [..._tags, tag];
        _suggestions = [
          for (final s in _suggestions)
            if (s.toLowerCase() != tag.name.toLowerCase()) s,
        ];
        _controller.clear();
      });
      widget.onChanged(_tags);
    } catch (e) {
      debugLogException('Featured tag create error', e);
      if (mounted) {
        setState(
          () => _error = upstreamFailureText(
            '#$name を追加できませんでした',
            e,
            reblogLabel: ref.read(reblogLabelProvider),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(FeaturedTag tag) async {
    final adapter = _adapter;
    if (adapter == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await adapter.unfeatureTag(tag.id);
      if (!mounted) return;
      setState(
        () => _tags = [
          for (final t in _tags)
            if (t.id != tag.id) t,
        ],
      );
      widget.onChanged(_tags);
    } catch (e) {
      debugLogException('Featured tag delete error', e);
      if (mounted) {
        setState(
          () => _error = upstreamFailureText(
            '#${tag.name} を外せませんでした',
            e,
            reblogLabel: ref.read(reblogLabelProvider),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suggestions = [
      for (final s in _suggestions)
        if (!_alreadyFeatured(s)) s,
    ];
    // ⚠ キーボードぶんとナビゲーションバーぶんを両方足す (#1062)。キーボードを
    // 閉じると viewInsets は 0 になり、下端の入力欄がナビゲーションバーに潜る。
    // 両者は二重には入らない（padding はキーボード表示中は 0 になる）。
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 +
            MediaQuery.viewInsetsOf(context).bottom +
            MediaQuery.paddingOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('紹介するハッシュタグ', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${_tags.length} / $featuredTagLimit 件',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            if (_tags.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'まだ紹介しているハッシュタグはありません',
                  style: theme.textTheme.bodyMedium,
                ),
              )
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in _tags)
                    InputChip(
                      label: Text('#${tag.name}'),
                      deleteButtonTooltipMessage: '#${tag.name} を外す',
                      onDeleted: _busy ? null : () => _remove(tag),
                    ),
                ],
              ),
            const SizedBox(height: 16),
            if (_full)
              Text(
                '紹介できるのは $featuredTagLimit 件までです。追加するには、どれかを外してください。',
                style: theme.textTheme.bodySmall,
              )
            else
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        hintText: 'ハッシュタグ',
                        prefixText: '#',
                        isDense: true,
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: _add,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy ? null : () => _add(_controller.text),
                    child: const Text('追加'),
                  ),
                ],
              ),
            if (_error case final error?) ...[
              const SizedBox(height: 8),
              Text(
                error,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (!_full && suggestions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                '最近使ったハッシュタグ',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in suggestions)
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 16),
                      label: Text('#$s'),
                      onPressed: _busy ? null : () => _add(s),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

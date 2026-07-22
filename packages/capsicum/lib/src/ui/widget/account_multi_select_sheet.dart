import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import 'emoji_text.dart';
import 'user_avatar.dart';

/// アカウントをサーバー検索して複数選択するボトムシート (#866)。
///
/// 選択結果（[User] のリスト）を返す。キャンセル時は null。コレクション作成の
/// 初期メンバー選択などで使う。プライバシー方針（フォロー外アカウントの追加導線を
/// 過度に作らない）に倣い、候補はサーバー検索結果ベースに留める。
///
/// [initial] は最初から選択済みにするアカウント。[excludeIds] は選択不可
/// （既にメンバー・自分など）で、候補に出ても選べないよう印を付ける。
Future<List<User>?> showAccountMultiSelectSheet(
  BuildContext context, {
  List<User> initial = const [],
  Set<String> excludeIds = const {},
}) {
  return showModalBottomSheet<List<User>>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        _AccountMultiSelectSheet(initial: initial, excludeIds: excludeIds),
  );
}

class _AccountMultiSelectSheet extends ConsumerStatefulWidget {
  const _AccountMultiSelectSheet({
    required this.initial,
    required this.excludeIds,
  });

  final List<User> initial;
  final Set<String> excludeIds;

  @override
  ConsumerState<_AccountMultiSelectSheet> createState() =>
      _AccountMultiSelectSheetState();
}

class _AccountMultiSelectSheetState
    extends ConsumerState<_AccountMultiSelectSheet> {
  final _controller = TextEditingController();
  final _searchFocus = FocusNode();

  /// 選択済み。検索し直しても保持できるよう id→User で持つ。
  late final Map<String, User> _selected = {
    for (final u in widget.initial) u.id: u,
  };

  List<User> _results = const [];
  bool _searching = false;
  String? _error;
  bool _focusRequested = false;

  @override
  void dispose() {
    _controller.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! SearchSupport) {
      setState(() {
        _searching = false;
        _error = 'この操作はこのサーバーでは使えません。';
      });
      return;
    }
    try {
      final users = await (adapter as SearchSupport).searchUsers(q);
      if (!mounted) return;
      setState(() {
        _results = users;
        _searching = false;
      });
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'collections.op',
        operation: 'search_member',
        error: e,
        stackTrace: st,
        account: ref.read(currentAccountProvider),
      );
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = '検索に失敗しました。';
      });
    }
  }

  void _toggle(User user) {
    setState(() {
      if (_selected.containsKey(user.id)) {
        _selected.remove(user.id);
      } else {
        _selected[user.id] = user;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_focusRequested) {
      _focusRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_searchFocus.context != null) _searchFocus.requestFocus();
      });
    }
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _controller,
                focusNode: _searchFocus,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'アカウントを検索',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null,
                ),
                onSubmitted: _search,
              ),
            ),
            if (_selected.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final u in _selected.values)
                        Chip(
                          label: Text(
                            '@${u.username}',
                            overflow: TextOverflow.ellipsis,
                          ),
                          onDeleted: () => _toggle(u),
                        ),
                    ],
                  ),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            Expanded(
              child: ListView.separated(
                itemCount: _results.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final user = _results[index];
                  final excluded = widget.excludeIds.contains(user.id);
                  final selected = _selected.containsKey(user.id);
                  return ListTile(
                    enabled: !excluded,
                    leading: UserAvatar(user: user, size: 40),
                    title: EmojiText(
                      user.displayName ?? user.username,
                      emojis: user.emojis,
                      fallbackHost: user.host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '@${user.username}${user.host != null ? '@${user.host}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: excluded
                        ? const Icon(Icons.check, color: Colors.grey)
                        : Checkbox(
                            value: selected,
                            onChanged: (_) => _toggle(user),
                          ),
                    onTap: excluded ? null : () => _toggle(user),
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('キャンセル'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, _selected.values.toList()),
                      child: Text('決定（${_selected.length}）'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

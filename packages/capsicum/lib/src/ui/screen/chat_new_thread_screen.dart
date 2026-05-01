import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/chat_provider.dart';
import '../widget/user_avatar.dart';

/// 新規 DM 相手を選ぶ画面。ユーザー検索 → タップで ChatThreadScreen へ遷移する。
/// Misskey の `canChat` フラグが false のユーザーは選択不可で表示する。
class ChatNewThreadScreen extends ConsumerStatefulWidget {
  const ChatNewThreadScreen({super.key});

  @override
  ConsumerState<ChatNewThreadScreen> createState() =>
      _ChatNewThreadScreenState();
}

class _ChatNewThreadScreenState extends ConsumerState<ChatNewThreadScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _query = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final results = _query.trim().isEmpty
        ? const AsyncValue<List<User>>.data([])
        : ref.watch(chatUserSearchProvider(_query.trim()));
    return Scaffold(
      appBar: AppBar(
        title: const Text('新しいメッセージ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _onChanged,
              decoration: const InputDecoration(
                hintText: 'ユーザー名で検索',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: results.when(
              data: (users) {
                if (_query.trim().isEmpty) {
                  return const Center(child: Text('ユーザー名を入力してください'));
                }
                if (users.isEmpty) {
                  return const Center(child: Text('該当ユーザーがいません'));
                }
                return ListView.separated(
                  itemCount: users.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) =>
                      _UserTile(user: users[index]),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    '検索に失敗しました\n$error',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UserTile extends StatelessWidget {
  final User user;

  const _UserTile({required this.user});

  @override
  Widget build(BuildContext context) {
    // canChat == null は不明（chat 概念のないサーバー or 古いフォーク）。
    // false のときだけ disabled 扱いにする。
    final disabled = user.canChat == false;
    final displayName = user.displayName?.isNotEmpty == true
        ? user.displayName!
        : user.username;
    final handle = user.host != null
        ? '@${user.username}@${user.host}'
        : '@${user.username}';
    return ListTile(
      leading: Opacity(
        opacity: disabled ? 0.5 : 1.0,
        child: UserAvatar(user: user, size: 40),
      ),
      title: Text(
        displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: disabled ? Theme.of(context).disabledColor : null,
        ),
      ),
      subtitle: Text(
        disabled ? '$handle ・ メッセージを利用できません' : handle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: disabled ? Theme.of(context).disabledColor : null,
        ),
      ),
      onTap: disabled
          ? null
          : () {
              context.pushReplacement('/chat/user/${user.id}', extra: user);
            },
    );
  }
}

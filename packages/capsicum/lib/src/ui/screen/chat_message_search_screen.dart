import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

import '../../model/account.dart';
import '../util/chat_error.dart';
import '../util/relative_time.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/user_avatar.dart';

/// チャットのスレッド / ルームの中を検索する (#1188)。
///
/// 選んだメッセージの id を返して閉じる（呼び出し側がその位置へ移る）。
///
/// ⚠⚠ **アダプタは呼び出し側から受け取る。**この画面は Navigator で全画面に
/// 積むので、`currentAdapterProvider` を読むとルート（現在のアカウント）の
/// アダプタになる。デッキで別アカウントのカラムから開いたとき、別のサーバーで
/// 検索してしまう（#1150 と同じ穴）。
class ChatMessageSearchScreen extends StatefulWidget {
  const ChatMessageSearchScreen({
    super.key,
    required this.support,
    required this.title,
    this.userId,
    this.roomId,
    this.account,
  });

  final ChatSupport support;

  /// 失敗の記録に載せるアカウント（[support] の持ち主）。
  final Account? account;

  /// 見出し（相手の名前・ルーム名）。
  final String title;
  final String? userId;
  final String? roomId;

  @override
  State<ChatMessageSearchScreen> createState() =>
      _ChatMessageSearchScreenState();
}

class _ChatMessageSearchScreenState extends State<ChatMessageSearchScreen> {
  final _controller = TextEditingController();
  List<ChatMessage>? _results;
  bool _searching = false;
  Object? _error;

  /// 検索の世代。⚠ 続けて検索したとき、前の検索の結果で上書きしない。
  int _generation = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    final generation = ++_generation;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await widget.support.searchChatMessages(
        query: query,
        userId: widget.userId,
        roomId: widget.roomId,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } catch (e, st) {
      reportChatOpFailure('search', e, st, account: widget.account);
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = e;
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          maxLength: 256, // 上流の上限
          decoration: InputDecoration(
            hintText: '${widget.title} のメッセージを検索',
            border: InputBorder.none,
            counterText: '',
          ),
          onSubmitted: (_) => _search(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '検索',
            onPressed: _searching ? null : _search,
          ),
        ],
      ),
      body: BottomSafeArea(child: _body(theme)),
    );
  }

  Widget _body(ThemeData theme) {
    if (_searching) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('検索に失敗しました'),
            const SizedBox(height: 8),
            TextButton(onPressed: _search, child: const Text('再試行')),
          ],
        ),
      );
    }
    final results = _results;
    if (results == null) return const SizedBox.shrink();
    if (results.isEmpty) {
      return const Center(child: Text('見つかりませんでした'));
    }
    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final message = results[index];
        final sender = message.fromUser;
        final name = sender.displayName?.isNotEmpty == true
            ? sender.displayName!
            : sender.username;
        return ListTile(
          leading: UserAvatar(user: sender, size: 36),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            message.text ?? (message.file != null ? '（ファイル）' : ''),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            formatRelativeTime(message.createdAt),
            style: theme.textTheme.bodySmall,
          ),
          onTap: () => Navigator.of(context).pop(message.id),
        );
      },
    );
  }
}

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/chat_provider.dart';
import '../util/chat_error.dart';
import '../util/op_error.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/retry_error_view.dart';

/// 自分宛のルーム招待一覧 (#438)。Accept (= join) で参加、Ignore で受信箱から
/// 取り除く。
class ChatInvitationsScreen extends ConsumerStatefulWidget {
  const ChatInvitationsScreen({super.key});

  @override
  ConsumerState<ChatInvitationsScreen> createState() =>
      _ChatInvitationsScreenState();
}

class _ChatInvitationsScreenState extends ConsumerState<ChatInvitationsScreen> {
  String? _pendingRoomId;

  Future<void> _accept(ChatRoomInvitation invitation) async {
    if (_pendingRoomId != null) return;
    // adapter チェックは setState より前に行う。アカウント切替の race で
    // ChatSupport でなくなった瞬間に setState 後の early return を踏むと、
    // _pendingRoomId が null に戻らずボタンが固着する (#298 系の chat 版)。
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ChatSupport) return;
    setState(() => _pendingRoomId = invitation.roomId);
    try {
      await (adapter as ChatSupport).joinRoom(invitation.roomId);
      ref.invalidate(chatInvitationInboxProvider);
      ref.invalidate(joiningChatRoomsProvider);
      ref.invalidate(chatThreadListProvider);
      if (!mounted) return;
      final room = invitation.room;
      if (room != null) {
        // 参加直後に room timeline へ。一覧から戻る導線は context.go で確保。
        context.pushReplacement('/chat/room/${room.id}', extra: room);
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('ルームに参加しました')));
      }
    } catch (e, st) {
      reportChatOpFailure(
        'accept_invitation',
        e,
        st,
        account: ref.accountForReport,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('参加に失敗しました (${summarizeOpError(e)})')),
      );
    } finally {
      if (mounted) setState(() => _pendingRoomId = null);
    }
  }

  Future<void> _ignore(ChatRoomInvitation invitation) async {
    if (_pendingRoomId != null) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ChatSupport) return;
    setState(() => _pendingRoomId = invitation.roomId);
    try {
      await (adapter as ChatSupport).ignoreInvitation(invitation.roomId);
      ref.invalidate(chatInvitationInboxProvider);
    } catch (e, st) {
      reportChatOpFailure(
        'ignore_invitation',
        e,
        st,
        account: ref.accountForReport,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('操作に失敗しました (${summarizeOpError(e)})')),
      );
    } finally {
      if (mounted) setState(() => _pendingRoomId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final invitations = ref.watch(chatInvitationInboxProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('ルーム招待'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: BottomSafeArea(
        child: invitations.when(
          data: (list) {
            if (list.isEmpty) {
              return const Center(child: Text('招待はありません'));
            }
            return RefreshIndicator(
              onRefresh: () => ref.refresh(chatInvitationInboxProvider.future),
              child: ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final invitation = list[index];
                  final room = invitation.room;
                  final pending = _pendingRoomId == invitation.roomId;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primaryContainer,
                      child: Icon(
                        Icons.groups,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    title: Text(
                      room?.name ?? '(不明なルーム)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: room?.description.isNotEmpty == true
                        ? Text(
                            room!.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          )
                        : null,
                    isThreeLine: room?.description.isNotEmpty == true,
                    trailing: pending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                onPressed: () => _ignore(invitation),
                                child: const Text('無視'),
                              ),
                              FilledButton(
                                onPressed: () => _accept(invitation),
                                child: const Text('参加'),
                              ),
                            ],
                          ),
                  );
                },
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => RetryErrorView(
            message: '読み込みに失敗しました\n${summarizeOpError(error)}',
            selectable: true,
            isRetrying: invitations.isLoading,
            onRetry: () => ref.invalidate(chatInvitationInboxProvider),
          ),
        ),
      ),
    );
  }
}

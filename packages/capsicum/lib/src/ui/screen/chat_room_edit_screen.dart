import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/chat_provider.dart';
import '../util/chat_error.dart';

/// 新規ルーム作成 / 既存ルーム編集を兼ねる画面 (#438)。[initialRoom] が null
/// なら作成、それ以外なら編集。Misskey の `/chat/rooms/{create,update}` を叩く。
class ChatRoomEditScreen extends ConsumerStatefulWidget {
  final ChatRoom? initialRoom;

  const ChatRoomEditScreen({super.key, this.initialRoom});

  bool get isEditing => initialRoom != null;

  @override
  ConsumerState<ChatRoomEditScreen> createState() => _ChatRoomEditScreenState();
}

class _ChatRoomEditScreenState extends ConsumerState<ChatRoomEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  final _formKey = GlobalKey<FormState>();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialRoom?.name ?? '');
    _description = TextEditingController(
      text: widget.initialRoom?.description ?? '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ChatSupport) return;
    final chat = adapter as ChatSupport;
    setState(() => _submitting = true);
    try {
      final ChatRoom room;
      if (widget.initialRoom == null) {
        room = await chat.createRoom(
          name: _name.text.trim(),
          description: _description.text.trim().isEmpty
              ? null
              : _description.text.trim(),
        );
      } else {
        room = await chat.updateRoom(
          roomId: widget.initialRoom!.id,
          name: _name.text.trim(),
          description: _description.text.trim(),
        );
      }
      ref.invalidate(joiningChatRoomsProvider);
      ref.invalidate(chatThreadListProvider);
      if (!mounted) return;
      if (widget.isEditing) {
        // 編集後は前画面 (timeline) に戻す。
        Navigator.of(context).pop(room);
      } else {
        // 作成後はそのままルーム timeline へ。一覧から戻れるよう pushReplacement。
        context.pushReplacement('/chat/room/${room.id}', extra: room);
      }
    } catch (e, st) {
      reportChatOpFailure(
        widget.isEditing ? 'update_room' : 'create_room',
        e,
        st,
        account: ref.read(currentAccountProvider),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${widget.isEditing ? "更新" : "作成"}に失敗しました (${summarizeChatError(e)})',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'ルームを編集' : '新しいルーム'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'ルーム名',
                    border: OutlineInputBorder(),
                  ),
                  // 256 chars は Misskey 側 paramDef の maxLength と一致。
                  maxLength: 256,
                  enabled: !_submitting,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'ルーム名を入力してください';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(
                    labelText: '説明 (任意)',
                    border: OutlineInputBorder(),
                  ),
                  // 1024 chars は Misskey 側 paramDef の maxLength と一致。
                  maxLength: 1024,
                  maxLines: 4,
                  minLines: 3,
                  enabled: !_submitting,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(widget.isEditing ? '更新' : '作成'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

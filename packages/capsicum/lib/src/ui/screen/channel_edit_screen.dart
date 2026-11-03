import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../util/compose_text_style.dart';
import '../util/op_error.dart';
import '../widget/bottom_safe_area.dart';

/// チャンネルの作成 / 編集 (#1051)。[channel] が null なら作成。
///
/// 保存できたら `true` を返して閉じる（一覧が取り直す）。失敗したら入力を残して
/// 留まる。
class ChannelEditScreen extends ConsumerStatefulWidget {
  const ChannelEditScreen({super.key, this.channel});

  final Channel? channel;

  @override
  ConsumerState<ChannelEditScreen> createState() => _ChannelEditScreenState();
}

class _ChannelEditScreenState extends ConsumerState<ChannelEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late bool _isSensitive;
  late bool _allowRenoteToExternal;
  bool _saving = false;

  /// 編集を始めたときのアカウント。⚠ 保存中にアカウントを切り替えられても、
  /// 始めたアカウントのアダプターで保存する（別アカウントへ書き込まない）。
  ChannelManagementSupport? _support;
  Account? _account;

  bool get _isNew => widget.channel == null;

  @override
  void initState() {
    super.initState();
    final channel = widget.channel;
    _name = TextEditingController(text: channel?.name ?? '');
    _description = TextEditingController(text: channel?.description ?? '');
    _isSensitive = channel?.isSensitive ?? false;
    _allowRenoteToExternal = channel?.allowRenoteToExternal ?? true;
    final adapter = ref.read(currentAdapterProvider);
    _support = adapter is ChannelManagementSupport
        ? adapter as ChannelManagementSupport
        : null;
    _account = ref.read(currentAccountProvider);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final support = _support;
    if (support == null || _saving) return;
    final messenger = ScaffoldMessenger.of(context);
    final name = _name.text.trim();
    if (name.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('名前を入れてください')));
      return;
    }
    final draft = ChannelDraft(
      name: name,
      description: _description.text.trim(),
      isSensitive: _isSensitive,
      allowRenoteToExternal: _allowRenoteToExternal,
    );
    setState(() => _saving = true);
    try {
      if (_isNew) {
        await support.createChannel(draft);
      } else {
        await support.updateChannel(widget.channel!.id, draft);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e, st) {
      reportOpFailure(
        tagKey: 'channel.op',
        operation: _isNew ? 'create' : 'update',
        error: e,
        stackTrace: st,
        account: _account,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(content: Text('チャンネルの保存に失敗しました\n${summarizeOpError(e)}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
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
          title: Text(_isNew ? 'チャンネルを作成' : 'チャンネルを編集'),
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
                maxLength: 128,
                decoration: const InputDecoration(labelText: '名前'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _description,
                maxLength: 2048,
                minLines: 3,
                maxLines: 8,
                style: composeTextStyle(ref),
                decoration: const InputDecoration(labelText: '説明'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('センシティブなチャンネル'),
                value: _isSensitive,
                onChanged: (value) => setState(() => _isSensitive = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('チャンネルの外へのリノートを許可'),
                value: _allowRenoteToExternal,
                onChanged: (value) =>
                    setState(() => _allowRenoteToExternal = value),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

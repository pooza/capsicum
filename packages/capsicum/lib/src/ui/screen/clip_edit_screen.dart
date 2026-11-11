import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/oauth_scope_error.dart';
import '../util/compose_text_style.dart';
import '../util/op_error.dart';
import '../widget/bottom_safe_area.dart';

/// クリップの作成 / 編集 (#1050)。[clip] が null なら作成。
///
/// 項目は名前・説明・公開の 3 つ（`clips/create` / `clips/update` の引数そのまま・
/// 2026-11-10 pooza）。型はアンテナの編集画面（#1052）と同じで、保存できたら
/// 作ったクリップ（編集なら `true`）を返して閉じる。失敗したら入力を残して留まる。
class ClipEditScreen extends ConsumerStatefulWidget {
  const ClipEditScreen({super.key, this.clip});

  final NoteClip? clip;

  @override
  ConsumerState<ClipEditScreen> createState() => _ClipEditScreenState();
}

class _ClipEditScreenState extends ConsumerState<ClipEditScreen> {
  /// Misskey の `clips/create` / `update` の `name: { maxLength: 100 }`。
  static const _nameMaxLength = 100;

  /// 同じく `description: { maxLength: 2048 }`。
  static const _descriptionMaxLength = 2048;

  late final TextEditingController _name;
  late final TextEditingController _description;
  late bool _isPublic;
  bool _saving = false;

  /// 編集を始めたときのアカウント。⚠ 保存中にアカウントを切り替えられても、
  /// 始めたアカウントのアダプターで保存する（別アカウントへ書き込まない）。
  ClipManagementSupport? _support;
  Account? _account;

  bool get _isNew => widget.clip == null;

  @override
  void initState() {
    super.initState();
    final clip = widget.clip;
    _name = TextEditingController(text: clip?.name ?? '');
    _description = TextEditingController(text: clip?.description ?? '');
    _isPublic = clip?.isPublic ?? false;
    final adapter = ref.read(currentAdapterProvider);
    _support = adapter is ClipManagementSupport
        ? adapter as ClipManagementSupport
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
    final draft = ClipDraft(
      name: name,
      description: _description.text,
      isPublic: _isPublic,
    );
    setState(() => _saving = true);
    try {
      if (_isNew) {
        final created = await support.createClip(draft);
        if (!mounted) return;
        Navigator.of(context).pop(created);
      } else {
        await support.updateClip(widget.clip!.id, draft);
        if (!mounted) return;
        Navigator.of(context).pop(true);
      }
    } on ClipLimitReached {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('このアカウントでは、これ以上クリップを作れません')),
      );
    } on ClipNotFound {
      // ⚠ Web などで既に消されていた。失敗として Sentry へ送らない。編集を
      // 続ける先が無いので、一覧へ戻って取り直させる。
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('このクリップは見つかりませんでした（削除された可能性があります）')),
      );
      Navigator.of(context).pop(true);
    } catch (e, st) {
      // ⚠ 権限の足りない古いトークンは送らない（再ログインで直る・#1361）。
      final scope = isOAuthScopeError(e);
      if (!scope) {
        reportOpFailure(
          tagKey: 'clip.op',
          operation: _isNew ? 'create' : 'update',
          error: e,
          stackTrace: st,
          account: _account,
        );
      }
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            scope
                ? oauthScopeErrorMessage
                : 'クリップの保存に失敗しました\n${summarizeOpError(e)}',
          ),
        ),
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
          title: Text(_isNew ? 'クリップを作成' : 'クリップを編集'),
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
                maxLength: _nameMaxLength,
                decoration: const InputDecoration(labelText: '名前'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _description,
                maxLength: _descriptionMaxLength,
                minLines: 2,
                maxLines: 6,
                style: composeTextStyle(ref),
                decoration: const InputDecoration(labelText: '説明（任意）'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('公開'),
                subtitle: const Text('オンにすると、プロフィールのクリップの一覧に並び、ほかの人も見られます'),
                value: _isPublic,
                onChanged: (v) => setState(() => _isPublic = v),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../service/sentry_op_failure.dart';

/// モロヘイヤ `ComposeTemplateContract::MAX_BODY_SIZE` の絶対上限 (#4457)。
/// サーバー投稿上限がこれを超えても、テンプレ本文はこの値で頭打ちになる。
const _templateBodyHardMax = 5000;

/// 投稿テンプレート一覧 (#767)。モロヘイヤの per-user CRUD API から取得する。
/// テンプレート機能を提供するサーバー（[MulukhiyaService.composeTemplatesEnabled]）
/// でのみ中身が入る。
final composeTemplatesProvider =
    FutureProvider.autoDispose<List<ComposeTemplate>>((ref) async {
      final account = ref.watch(currentAccountProvider);
      final mulukhiya = account?.mulukhiya;
      if (account == null ||
          mulukhiya == null ||
          !mulukhiya.composeTemplatesEnabled) {
        return [];
      }
      return mulukhiya.getComposeTemplates(
        accessToken: account.userSecret.accessToken,
      );
    });

/// 投稿テンプレートの管理画面 (#767)。作成・編集・削除と、テンプレートからの
/// 投稿開始を行う。適用（本文差し替え）は compose 画面の選択シートが担う。
class TemplatesManageScreen extends ConsumerWidget {
  const TemplatesManageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templatesAsync = ref.watch(composeTemplatesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('投稿テンプレート')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _create(context, ref),
        tooltip: 'テンプレートを作成',
        child: const Icon(Icons.add),
      ),
      body: templatesAsync.when(
        data: (templates) {
          if (templates.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'テンプレートはありません。\n右下の＋から作成できます。',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: templates.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final t = templates[index];
              return _TemplateTile(
                template: t,
                onEdit: () => _edit(context, ref, t),
                onCompose: () => _compose(context, t),
                onDelete: () => _confirmDelete(context, ref, t),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('読み込みに失敗しました\n$error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref.invalidate(composeTemplatesProvider),
                  child: const Text('再試行'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// テンプレートから compose を開く（新規画面なので上書き確認は不要）。
  Future<void> _compose(BuildContext context, ComposeTemplate template) async {
    await context.push('/compose', extra: {'template': template});
  }

  /// 本文入力の上限。サーバー投稿上限（プリセットで 3000）を使い、モロヘイヤ側
  /// API の絶対上限 5000 で頭打ちにする。未取得時は 5000 にフォールバック。
  int _bodyMaxLength(WidgetRef ref) {
    final serverMax = ref.read(maxPostLengthProvider);
    if (serverMax == null || serverMax > _templateBodyHardMax) {
      return _templateBodyHardMax;
    }
    return serverMax;
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final result = await _showEditor(
      context,
      maxBodyLength: _bodyMaxLength(ref),
    );
    if (result == null || !context.mounted) return;
    final account = ref.read(currentAccountProvider);
    final mulukhiya = account?.mulukhiya;
    if (account == null || mulukhiya == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await mulukhiya.createComposeTemplate(
        accessToken: account.userSecret.accessToken,
        name: result.name,
        body: result.body,
        cw: result.cw,
      );
      ref.invalidate(composeTemplatesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('テンプレートを作成しました')));
    } catch (e, st) {
      _reportAndNotify(messenger, ref, 'create', e, st);
    }
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    ComposeTemplate template,
  ) async {
    final result = await _showEditor(
      context,
      initial: template,
      maxBodyLength: _bodyMaxLength(ref),
    );
    if (result == null || !context.mounted) return;
    final account = ref.read(currentAccountProvider);
    final mulukhiya = account?.mulukhiya;
    if (account == null || mulukhiya == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await mulukhiya.updateComposeTemplate(
        accessToken: account.userSecret.accessToken,
        id: template.id,
        name: result.name,
        body: result.body,
        cw: result.cw,
      );
      ref.invalidate(composeTemplatesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('テンプレートを更新しました')));
    } catch (e, st) {
      _reportAndNotify(messenger, ref, 'update', e, st);
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    ComposeTemplate template,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('テンプレートの削除'),
        content: Text('「${template.name}」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final account = ref.read(currentAccountProvider);
    final mulukhiya = account?.mulukhiya;
    if (account == null || mulukhiya == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await mulukhiya.deleteComposeTemplate(
        accessToken: account.userSecret.accessToken,
        id: template.id,
      );
      ref.invalidate(composeTemplatesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('テンプレートを削除しました')));
    } catch (e, st) {
      _reportAndNotify(messenger, ref, 'delete', e, st);
    }
  }

  /// 失敗を計装しつつ、ユーザーには理由の当たりを付けた SnackBar で通知する。
  void _reportAndNotify(
    ScaffoldMessengerState messenger,
    WidgetRef ref,
    String operation,
    Object error,
    StackTrace st,
  ) {
    final status = error is DioException ? error.response?.statusCode : null;
    final message = switch (status) {
      409 => 'テンプレートの上限（50 件）に達しています',
      422 => '入力内容が不正です（名前・本文の長さを確認してください）',
      404 => 'テンプレートが見つかりません（既に削除された可能性があります）',
      _ => '操作に失敗しました',
    };
    messenger.showSnackBar(SnackBar(content: Text(message)));
    reportOpFailure(
      tagKey: 'template.op',
      operation: operation,
      error: error,
      stackTrace: st,
      account: ref.read(currentAccountProvider),
    );
  }
}

/// テンプレートの作成・編集ダイアログ。返り値は入力値（キャンセルは null）。
/// `name` は必須・非空、`body` は空を許容、`cw` は空なら null。
Future<({String name, String body, String? cw})?> _showEditor(
  BuildContext context, {
  ComposeTemplate? initial,
  required int maxBodyLength,
}) {
  return showDialog<({String name, String body, String? cw})>(
    context: context,
    builder: (context) =>
        _TemplateEditorDialog(initial: initial, maxBodyLength: maxBodyLength),
  );
}

class _TemplateTile extends StatelessWidget {
  final ComposeTemplate template;
  final VoidCallback onEdit;
  final VoidCallback onCompose;
  final VoidCallback onDelete;

  const _TemplateTile({
    required this.template,
    required this.onEdit,
    required this.onCompose,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final body = template.body.trim();
    return ListTile(
      onTap: onEdit,
      leading: const Icon(Icons.description_outlined),
      title: Text(template.name),
      subtitle: Text(
        body.isEmpty ? '(本文なし)' : body.replaceAll('\n', ' '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          switch (value) {
            case 'compose':
              onCompose();
            case 'edit':
              onEdit();
            case 'delete':
              onDelete();
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'compose',
            child: ListTile(
              leading: Icon(Icons.edit_outlined),
              title: Text('このテンプレで投稿'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem(
            value: 'edit',
            child: ListTile(
              leading: Icon(Icons.tune),
              title: Text('編集'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading: Icon(Icons.delete_outline),
              title: Text('削除'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }
}

class _TemplateEditorDialog extends StatefulWidget {
  final ComposeTemplate? initial;
  final int maxBodyLength;

  const _TemplateEditorDialog({this.initial, required this.maxBodyLength});

  @override
  State<_TemplateEditorDialog> createState() => _TemplateEditorDialogState();
}

class _TemplateEditorDialogState extends State<_TemplateEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _bodyController;
  late final TextEditingController _cwController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initial?.name ?? '');
    _bodyController = TextEditingController(text: widget.initial?.body ?? '');
    _cwController = TextEditingController(text: widget.initial?.cw ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bodyController.dispose();
    _cwController.dispose();
    super.dispose();
  }

  void _submit() {
    final cw = _cwController.text.trim();
    Navigator.pop(context, (
      name: _nameController.text.trim(),
      body: _bodyController.text,
      cw: cw.isEmpty ? null : cw,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'テンプレートを作成' : 'テンプレートを編集'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              maxLength: 100,
              decoration: const InputDecoration(
                labelText: '名前',
                hintText: '例: 実況会お知らせ',
              ),
            ),
            TextField(
              controller: _bodyController,
              maxLength: widget.maxBodyLength,
              maxLines: 5,
              minLines: 3,
              decoration: const InputDecoration(labelText: '本文（空でも可）'),
            ),
            TextField(
              controller: _cwController,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'CW（任意）',
                hintText: '閲覧注意の見出し',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _nameController,
          builder: (context, value, _) => TextButton(
            onPressed: value.text.trim().isEmpty ? null : _submit,
            child: const Text('保存'),
          ),
        ),
      ],
    );
  }
}

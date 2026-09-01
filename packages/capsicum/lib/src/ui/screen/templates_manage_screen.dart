import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../util/compose_template_display.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/retry_error_view.dart';

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
      try {
        return await mulukhiya.getComposeTemplates(
          accessToken: account.userSecret.accessToken,
        );
      } catch (e, st) {
        // 一覧取得の恒常的失敗（サーバー 5xx 等）を可視化する。CRUD と観測性を
        // 揃える（collections.op の load 計装と同様）。UI へは rethrow で表示。
        reportOpFailure(
          tagKey: 'template.op',
          operation: 'load_list',
          error: e,
          stackTrace: st,
          account: account,
        );
        rethrow;
      }
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
      body: BottomSafeArea(
        child: templatesAsync.when(
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
          error: (_, _) => RetryErrorView(
            message: 'テンプレートの読み込みに失敗しました',
            isRetrying: templatesAsync.isLoading,
            onRetry: () => ref.invalidate(composeTemplatesProvider),
          ),
        ),
      ),
    );
  }

  /// テンプレートから compose を開く（新規画面なので上書き確認は不要）。
  Future<void> _compose(BuildContext context, ComposeTemplate template) async {
    await context.push('/compose', extra: {'template': template});
  }

  /// 本文入力の上限。テンプレ本文はそのまま投稿されるわけではないが、投稿可能
  /// 文字数を超える意味はないため、投稿フォームと同じ [maxPostLengthProvider] を
  /// 使う（サーバー値、無ければ Mastodon 500 / Misskey 3000 の adapter 既定）。
  /// アダプタ不在の稀な null 時のみ上限なしにする。
  int? _bodyMaxLength(WidgetRef ref) => ref.read(maxPostLengthProvider);

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
      // 画面を離脱していたら ref は破棄済みで invalidate が投げる。ガードする。
      if (!context.mounted) return;
      ref.invalidate(composeTemplatesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('テンプレートを作成しました')));
    } catch (e, st) {
      _reportAndNotify(messenger, account, 'create', e, st);
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
      if (!context.mounted) return;
      ref.invalidate(composeTemplatesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('テンプレートを更新しました')));
    } catch (e, st) {
      _reportAndNotify(messenger, account, 'update', e, st);
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
      if (!context.mounted) return;
      ref.invalidate(composeTemplatesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('テンプレートを削除しました')));
    } catch (e, st) {
      _reportAndNotify(messenger, account, 'delete', e, st);
    }
  }

  /// 失敗を計装しつつ、ユーザーには理由の当たりを付けた SnackBar で通知する。
  /// 想定内のクライアントエラー（409 上限 / 422 検証 / 404 競合削除）は SnackBar
  /// で案内するに留め、Sentry には上げない（サーバー側も 4xx は log 止まりで、
  /// `template.op` の fingerprint を実障害だけに保つため）。account は await 前に
  /// 捕捉した値を渡す（ここで ref.read すると画面離脱後に StateError を投げる）。
  void _reportAndNotify(
    ScaffoldMessengerState messenger,
    Account? account,
    String operation,
    Object error,
    StackTrace st,
  ) {
    final status = error is DioException ? error.response?.statusCode : null;
    final message = composeTemplateErrorMessage(error, fallback: '操作に失敗しました');
    messenger.showSnackBar(SnackBar(content: Text(message)));
    // 想定内の 4xx は計装しない（5xx / ネットワーク / 非 Dio 例外のみ上げる）。
    if (status != null && status < 500) return;
    reportOpFailure(
      tagKey: 'template.op',
      operation: operation,
      error: error,
      stackTrace: st,
      account: account,
    );
  }
}

/// テンプレートの作成・編集ダイアログ。返り値は入力値（キャンセルは null）。
/// `name` は必須・非空、`body` は空を許容、`cw` は空なら null。
Future<({String name, String body, String? cw})?> _showEditor(
  BuildContext context, {
  ComposeTemplate? initial,
  required int? maxBodyLength,
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
    return ListTile(
      onTap: onEdit,
      leading: const Icon(Icons.description_outlined),
      title: Text(template.name),
      subtitle: Text(
        composeTemplateBodyPreview(template),
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
  final int? maxBodyLength;

  const _TemplateEditorDialog({this.initial, required this.maxBodyLength});

  @override
  State<_TemplateEditorDialog> createState() => _TemplateEditorDialogState();
}

class _TemplateEditorDialogState extends State<_TemplateEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _bodyController;
  late final TextEditingController _cwController;
  final _nameFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initial?.name ?? '');
    _bodyController = TextEditingController(text: widget.initial?.body ?? '');
    _cwController = TextEditingController(text: widget.initial?.cw ?? '');
    // macOS の showDialog + autofocus は barrier の FocusScope と競合して
    // キー入力を取りこぼす（#722）。autofocus を使わず post-frame で明示要求する。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nameFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bodyController.dispose();
    _cwController.dispose();
    _nameFocus.dispose();
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
    // AlertDialog は中身の高さに合わせて縮むため、本文を固定行数にするとダイアログが
    // 短いまま上下に大きな余白が残る。本文欄を Expanded で残り高さいっぱいに伸ばし、
    // 内容の高さを利用可能高さ（キーボード分を除く）に合わせて余白を詰める。
    final media = MediaQuery.of(context);
    // title / actions / insetPadding / 各欄のカウンタ等の実測ぶんを差し引く概算。
    final contentHeight = (media.size.height - media.viewInsets.bottom - 260)
        .clamp(240.0, 640.0);
    return AlertDialog(
      // 画面端までの余白を詰めてダイアログを広く取る（既定は左右 40 / 上下 24）。
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      title: Text(widget.initial == null ? 'テンプレートを作成' : 'テンプレートを編集'),
      content: SizedBox(
        width: double.maxFinite,
        height: contentHeight,
        child: Column(
          children: [
            TextField(
              controller: _nameController,
              focusNode: _nameFocus,
              maxLength: 100,
              decoration: const InputDecoration(
                labelText: '名前',
                hintText: '例: 実況会お知らせ',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            // 本文は残り高さいっぱいに広げる。超過分は欄内でスクロールする。
            Expanded(
              child: TextField(
                controller: _bodyController,
                maxLength: widget.maxBodyLength,
                expands: true,
                maxLines: null,
                minLines: null,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(
                  labelText: '本文（空でも可）',
                  border: OutlineInputBorder(),
                  // 複数行なのでラベルを枠の上端に揃える。
                  alignLabelWithHint: true,
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _cwController,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'CW（任意）',
                hintText: '閲覧注意の見出し',
                border: OutlineInputBorder(),
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

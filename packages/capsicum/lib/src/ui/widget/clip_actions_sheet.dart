import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/clip_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/oauth_scope_error.dart';
import '../util/op_error.dart';
import '../util/provider_scope_carrier.dart';

enum _ClipAction { edit, delete }

/// クリップの操作のシート (#1050)。管理画面の行とクリップの画面から開く。
///
/// 削除できたら `true` を返す（クリップの画面は閉じる）。型はアンテナ
/// （#1052・`antenna_actions_sheet.dart`）と同じ。
///
/// ⚠ 楽観的に表示を変えない。送って成功してから取り直す
/// （`docs/product-policy.md`「閲覧のみの族の型」）。
Future<bool> showClipActions(
  BuildContext context,
  WidgetRef ref,
  NoteClip clip,
) async {
  final adapter = ref.read(currentAdapterProvider);
  if (adapter is! ClipManagementSupport) return false;
  final support = adapter as ClipManagementSupport;
  final account = ref.read(currentAccountProvider);
  final messenger = ScaffoldMessenger.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  // 編集の画面へ開いた側のスコープを運ぶ（`await` の前に作っておく）。
  final editExtra = extraWithProviderScope(context, {'clip': clip});

  final action = await showModalBottomSheet<_ClipAction>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('編集'),
            onTap: () => Navigator.pop(sheetContext, _ClipAction.edit),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('削除'),
            onTap: () => Navigator.pop(sheetContext, _ClipAction.delete),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return false;

  if (action == _ClipAction.edit) {
    final saved = await context.push<bool>('/clips/edit', extra: editExtra);
    // ⚠ 編集の間に行が破棄されていることがあるので、コンテナへ当てる。
    if (saved == true) container.invalidate(clipsProvider);
    return false;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('クリップを削除'),
      content: Text('「${clip.name}」を削除します。入れた投稿は消えません。元に戻せません。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('削除'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;

  try {
    await support.deleteClip(clip.id);
  } catch (e, st) {
    // ⚠ 権限の足りない古いトークンは送らない（再ログインで直る・#1361）。
    final scope = isOAuthScopeError(e);
    if (!scope) {
      reportOpFailure(
        tagKey: 'clip.op',
        operation: 'delete',
        error: e,
        stackTrace: st,
        account: account,
      );
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          scope
              ? oauthScopeErrorMessage
              : 'クリップの削除に失敗しました\n${summarizeOpError(e)}',
        ),
      ),
    );
    return false;
  }
  // ⚠ 通信の間に行が破棄されていると `ref` は触れないので、コンテナへ当てる。
  container.invalidate(clipsProvider);
  messenger.showSnackBar(const SnackBar(content: Text('クリップを削除しました')));
  return true;
}

/// クリップの公開 / 非公開の印のアイコン (#1050)。管理画面と追加のシートで揃える。
IconData clipVisibilityIcon(NoteClip clip) =>
    clip.isPublic ? Icons.content_paste : Icons.lock_outline;

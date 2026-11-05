import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/antenna_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/oauth_scope_error.dart';
import '../util/op_error.dart';

enum _AntennaAction { edit, delete }

/// アンテナの操作のシート (#1052)。管理画面の行とアンテナの画面から開く。
///
/// 削除できたら `true` を返す（アンテナの画面は閉じる）。
///
/// ⚠ 楽観的に表示を変えない。送って成功してから取り直す
/// （`docs/product-policy.md`「閲覧のみの族の型」）。
Future<bool> showAntennaActions(
  BuildContext context,
  WidgetRef ref,
  Antenna antenna,
) async {
  final adapter = ref.read(currentAdapterProvider);
  if (adapter is! AntennaManagementSupport) return false;
  final support = adapter as AntennaManagementSupport;
  final account = ref.read(currentAccountProvider);
  final messenger = ScaffoldMessenger.of(context);
  final container = ProviderScope.containerOf(context, listen: false);

  final action = await showModalBottomSheet<_AntennaAction>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('編集'),
            onTap: () => Navigator.pop(sheetContext, _AntennaAction.edit),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('削除'),
            onTap: () => Navigator.pop(sheetContext, _AntennaAction.delete),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return false;

  if (action == _AntennaAction.edit) {
    final saved = await context.push<bool>('/antennas/edit', extra: antenna);
    // ⚠ 編集の間に行が破棄されていることがあるので、コンテナへ当てる。
    // アンテナの画面から開いたときは、条件を変えた結果も取り直す。
    if (saved == true) {
      container.invalidate(antennasProvider);
      container.invalidate(antennaNotesProvider(antenna.id));
    }
    return false;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('アンテナを削除'),
      content: Text('「${antenna.name}」を削除します。元に戻せません。'),
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
    await support.deleteAntenna(antenna.id);
  } catch (e, st) {
    // ⚠ 権限の足りない古いトークンは送らない（再ログインで直る・#1361）。
    final scope = isOAuthScopeError(e);
    if (!scope) {
      reportOpFailure(
        tagKey: 'antenna.op',
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
              : 'アンテナの削除に失敗しました\n${summarizeOpError(e)}',
        ),
      ),
    );
    return false;
  }
  // ⚠ 通信の間に行が破棄されていると `ref` は触れないので、コンテナへ当てる。
  container.invalidate(antennasProvider);
  messenger.showSnackBar(const SnackBar(content: Text('アンテナを削除しました')));
  return true;
}

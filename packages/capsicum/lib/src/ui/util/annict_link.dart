import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../url_helper.dart';

/// Annict OAuth 連携フロー (確認 → ブラウザ認可 → コード入力 → トークン交換)。
///
/// エピソードブラウザと感想投稿画面の両方から呼ばれる共通導線 (#298)。
/// 番組表→感想投稿が主要導線なので、エピソードブラウザに寄り道せず
/// その場で連携を完結できるようにここへ抽出した。連携成功で true。
Future<bool> runAnnictLinkFlow(BuildContext context, WidgetRef ref) async {
  final mulukhiya = ref.read(currentMulukhiyaProvider);
  final account = ref.read(currentAccountProvider);
  if (mulukhiya == null || account == null) return false;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Annict 連携'),
      content: const Text(
        'Annict アカウントとの連携が必要です。\n\n'
        'ブラウザで Annict の認可画面を開き、表示されるコードを入力してください。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('連携する'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;

  try {
    final oauthUri = await mulukhiya.getAnnictOAuthUri();
    final uri = Uri.parse(oauthUri);
    if (!await launchUrlSafely(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('ブラウザを開けませんでした')));
      }
      return false;
    }
    if (!context.mounted) return false;

    final code = await _showCodeInputDialog(context);
    if (code == null || code.trim().isEmpty || !context.mounted) return false;

    await mulukhiya.authenticateAnnict(
      snsToken: account.userSecret.accessToken,
      annictCode: code.trim(),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Annict 連携が完了しました')));
    }
    return true;
  } catch (e) {
    debugPrint('Annict auth error: $e');
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Annict 連携に失敗しました')));
    }
    return false;
  }
}

Future<String?> _showCodeInputDialog(BuildContext context) async {
  final codeController = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('認可コードの入力'),
        content: TextField(
          controller: codeController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Annict で表示されたコードを貼り付け',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, codeController.text),
            child: const Text('認証'),
          ),
        ],
      ),
    );
  } finally {
    codeController.dispose();
  }
}

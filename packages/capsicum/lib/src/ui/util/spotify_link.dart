import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../util/exception_scrub.dart';
import '../../url_helper.dart';
import 'launch_url_toast.dart';

/// Spotify OAuth 連携フロー (確認 → ブラウザ認可 → コード入力 → トークン交換)
/// (#570)。Annict 連携 ([runAnnictLinkFlow]) と同じ「サーバー保管型 OAuth」UX。
///
/// 連携成功で true。成功 / 失敗いずれでも呼び出し側は `redetectMulukhiya` で
/// `spotify_linked` を更新してから UI を出し直すこと (本関数は state を触らない)。
Future<bool> runSpotifyLinkFlow(BuildContext context, WidgetRef ref) async {
  final mulukhiya = ref.read(currentMulukhiyaProvider);
  final account = ref.read(currentAccountProvider);
  if (mulukhiya == null || account == null) return false;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Spotify 連携'),
      content: const Text(
        'Spotify アカウントとの連携が必要です。\n\n'
        'ブラウザで Spotify の認可画面を開き、表示されるコードを入力してください。',
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
    final oauthUri = await mulukhiya.getSpotifyOAuthUri();
    final uri = Uri.parse(oauthUri);
    if (!context.mounted) return false;
    // 失敗時の SnackBar は共通ヘルパーへ寄せた (#976)。⚠ **ヘルパーは入口で
    // messenger を捕まえるので、ここで mounted を見てから渡す**（OAuth URI の
    // 取得を挟んでいるため、この時点で画面が消えていることがある）。
    if (!await launchUrlOrToast(
      context,
      uri,
      mode: LaunchMode.externalApplication,
    )) {
      return false;
    }
    if (!context.mounted) return false;

    final code = await _showCodeInputDialog(context);
    if (code == null || code.trim().isEmpty || !context.mounted) return false;

    await mulukhiya.authenticateSpotify(
      snsToken: account.userSecret.accessToken,
      code: code.trim(),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Spotify 連携が完了しました')));
    }
    return true;
  } catch (e) {
    debugLogException('Spotify auth error', e);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Spotify 連携に失敗しました')));
    }
    return false;
  }
}

/// Spotify 連携を解除する (#570)。成功で true。
Future<bool> runSpotifyUnlinkFlow(BuildContext context, WidgetRef ref) async {
  final mulukhiya = ref.read(currentMulukhiyaProvider);
  final account = ref.read(currentAccountProvider);
  if (mulukhiya == null || account == null) return false;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Spotify 連携解除'),
      content: const Text('Spotify との連携を解除します。よろしいですか？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('解除する'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;

  try {
    await mulukhiya.unlinkSpotify(account.userSecret.accessToken);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Spotify 連携を解除しました')));
    }
    return true;
  } catch (e) {
    debugLogException('Spotify unlink error', e);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('連携解除に失敗しました')));
    }
    return false;
  }
}

Future<String?> _showCodeInputDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (context) => const _CodeInputDialog(),
  );
}

/// controller のライフサイクルをダイアログの State に束ねる ([annict_link] と
/// 同じく、閉じるアニメーション中の "used after being disposed" を避けるため)。
class _CodeInputDialog extends StatefulWidget {
  const _CodeInputDialog();

  @override
  State<_CodeInputDialog> createState() => _CodeInputDialogState();
}

class _CodeInputDialogState extends State<_CodeInputDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('認可コードの入力'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Spotify で表示されたコードを貼り付け',
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
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('認証'),
        ),
      ],
    );
  }
}

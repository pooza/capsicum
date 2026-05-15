import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// OAuth トークンのスコープ不足 (`isOAuthScopeError` 判定) を検出したときに
/// 表示する案内ビュー (#441)。
///
/// 「このアカウントを再ログインしてください」というメッセージと、サーバー選択
/// 画面へ戻す導線（OAuth フローを起こし直すボタン）を提供する。
class OAuthScopeErrorView extends StatelessWidget {
  const OAuthScopeErrorView({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            const Text(
              'このアカウントは新しい機能の権限を持っていません。\n'
              '再ログインしてください。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.login),
              label: const Text('再ログイン'),
              onPressed: () => context.go('/server'),
            ),
          ],
        ),
      ),
    );
  }
}

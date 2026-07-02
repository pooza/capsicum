import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../constants.dart';
import '../../platform/platform_info.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/supporter_purchase_provider.dart';
import '../../service/push_registration_service.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(currentAccountProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('アカウント設定'),
            subtitle: account != null
                ? Text('@${account.key.username}@${account.key.host}')
                : null,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/account'),
          ),
          ListTile(
            leading: const Icon(Icons.palette),
            title: const Text('テーマ'),
            subtitle: const Text('配色・文字サイズ'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/appearance'),
          ),
          ListTile(
            leading: const Icon(Icons.visibility),
            title: const Text('表示'),
            subtitle: const Text('タイムライン表示の設定'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/display'),
          ),
          ListTile(
            leading: const Icon(Icons.touch_app),
            title: const Text('タッチ操作'),
            subtitle: const Text('投稿のボタンをタイル上に表示する'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/touch'),
          ),
          // デスクトップ専用設定（常駐 #752 / ログイン時起動 #751 / マウスドラッグ
          // スクロール #574 / 起動時更新確認 #641）。モバイルでは出さない。
          if (isDesktop)
            ListTile(
              leading: const Icon(Icons.desktop_windows),
              title: const Text('デスクトップ'),
              subtitle: const Text('ウィンドウ常駐・ログイン時起動など'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/desktop'),
            ),
          // macOS / Linux / Windows は push 通知を本配線していない
          // (#467 / #471 / #423)。本配線が入るまで設定エントリも隠す。
          if (PushRegistrationService.isPushBackendWired)
            ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('プッシュ通知'),
              subtitle: const Text('アカウント別の登録状況・再試行'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/push'),
            ),
          // 投げ銭の購入導線は iOS / Android / macOS、および Store 版 Windows
          // (#599 §E-2)。push 設定と同じく、対応しない環境では設定エントリを隠す。
          // Windows は Store 版でのみ購入が成立するため、商品問い合わせが通った
          // ときだけ出す（判定は supporterEntryVisibleProvider）。
          if (ref.watch(supporterEntryVisibleProvider))
            ListTile(
              leading: Image.asset(
                AppConstants.supporterIconAsset,
                width: 30,
                height: 30,
              ),
              title: const Text('capsicum をサポート'),
              subtitle: const Text('投げ銭で開発と通知リレーを応援'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/supporter'),
            ),
        ],
      ),
    );
  }
}

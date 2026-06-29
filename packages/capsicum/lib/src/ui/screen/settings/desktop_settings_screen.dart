import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../platform/platform_info.dart';
import '../../../provider/preferences_provider.dart';
import '../../../service/launch_at_login_service.dart';
import '../../../service/resident_mode_service.dart';
import '../../../service/update_checker.dart';

/// デスクトップ（macOS / Linux / Windows）専用の設定をまとめた画面。
///
/// ウィンドウ常駐 (#752) / ログイン時起動 (#751) などデスクトップでしか意味を
/// 持たない項目は、モバイルと共通の「表示」設定に混ぜると過密になるため、
/// ここへ分離する。各項目はさらに OS / 配布チャネルでゲートする（常駐は
/// Windows + macOS メニューバー + Linux トレイ、ログイン時起動は Windows のみ
/// 〔macOS はシステム設定での手動登録に委ねる・#757〕、更新確認は直配チャネル
/// のみ）。
class DesktopSettingsScreen extends ConsumerWidget {
  const DesktopSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('デスクトップ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          // マウスドラッグでのスクロールはデスクトップ専用 (#574)。トラック
          // パッド 2 本指スワイプとの両立が崩れるケースがあるためオプトイン。
          if (isDesktop)
            SwitchListTile(
              title: const Text('マウスドラッグでスクロール'),
              subtitle: const Text(
                'Drawer・タブ列をマウスで掴んで横スクロールできるようにします。'
                'トラックパッドの 2 本指スワイプが効きにくくなることがあります',
              ),
              value: ref.watch(mouseDragScrollProvider),
              onChanged: (value) =>
                  ref.read(mouseDragScrollProvider.notifier).setEnabled(value),
            ),
          // 常駐モード (#752)。ウィンドウを閉じてもトレイ / メニューバーに
          // 常駐し、通知 (#569 WebSocket) を受け続ける。Windows（v1.40）+ macOS
          // メニューバー + Linux トレイ（#757）で有効。Linux はトレイ非対応 DE
          // でも最小化フォールバックで安全（ResidentModeService 参照）。
          if (ResidentModeService.isSupported)
            SwitchListTile(
              title: const Text('ウィンドウを閉じても常駐'),
              subtitle: Text(
                'オンにすると、ウィンドウを閉じてもアプリは終了せず'
                '$residentTargetLabelに常駐し、通知を受け続けます',
              ),
              value: ref.watch(residentModeProvider),
              onChanged: (value) =>
                  ref.read(residentModeProvider.notifier).setEnabled(value),
            ),
          // ログイン時起動 (#751)。OS のログイン時に capsicum を自動起動。
          // 常駐 (#752) と組み合わせると「ログイン → 常駐 → 通知を受け続ける」
          // が成立する。Windows のみ。macOS はシステム設定 →「一般」→「ログイン
          // 項目」、Linux は ~/.config/autostart（INSTALL.md に手順）での手動
          // 登録に委ねる（自動化が配布チャネル / ネイティブ統合に見合わない
          // ため・#757）。詳細は LaunchAtLoginService の doc を参照。
          if (LaunchAtLoginService.isSupported)
            SwitchListTile(
              title: const Text('ログイン時に起動'),
              subtitle: const Text(
                'OS にログインしたとき capsicum を自動的に起動します。'
                '「ウィンドウを閉じても常駐」と併用すると常に通知を受け取れます',
              ),
              value: ref.watch(launchAtLoginProvider),
              onChanged: (value) =>
                  ref.read(launchAtLoginProvider.notifier).setEnabled(value),
            ),
          // 直配チャネル (Linux AppImage / Windows 自己署名 MSIX 直配) のみ
          // 意味がある設定 (#641)。ストア配布ビルドでは
          // [kIsDirectChannelBuild] が false なので、設定エントリ自体を隠す。
          if (kIsDirectChannelBuild)
            SwitchListTile(
              title: const Text('起動時に新しいバージョンを確認'),
              subtitle: const Text(
                'GitHub Releases の最新版を確認し、新しいバージョンがあれば通知します',
              ),
              value: ref.watch(updateCheckEnabledProvider),
              onChanged: (value) => ref
                  .read(updateCheckEnabledProvider.notifier)
                  .setEnabled(value),
            ),
        ],
      ),
    );
  }
}

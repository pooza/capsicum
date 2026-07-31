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
          // 投稿本文のフォント指定 (#892)。端末インストール済みの等幅フォントを
          // ファミリ名で指定する。デスクトップ (Linux/macOS/Windows) のみ意味が
          // ある（iOS/Android は任意フォントを通常インストール不可で no-op）。
          if (isDesktop) const _ComposeFontSetting(),
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

/// 投稿本文のフォント指定 (#892)。ファミリ名の自由入力欄＋ライブプレビュー行。
///
/// ドロップダウンにしないのは、Flutter にインストール済みフォントを列挙する
/// 標準 API がなく、ピッカーは OS ごとのネイティブ実装が必要で重すぎるため。
/// 対象は正確なファミリ名（例: `HackGen Console`）を打てる技術志向ユーザー。
/// 空欄＝既定フォントで、トグルを兼ねる。未インストール・誤入力は OS の
/// フォント解決が黙って既定へフォールバックするため、効いたか一目で分かる
/// よう全角／半角混じりのプレビュー行を添える。
class _ComposeFontSetting extends ConsumerStatefulWidget {
  const _ComposeFontSetting();

  @override
  ConsumerState<_ComposeFontSetting> createState() =>
      _ComposeFontSettingState();
}

class _ComposeFontSettingState extends ConsumerState<_ComposeFontSetting> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(composeFontFamilyProvider),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fontFamily = ref.watch(composeFontFamilyProvider);
    // provider は初回 build で '' を返し、保存値を非同期に読んでから差し替える。
    // その読み込み前にこの画面を開くと、controller が '' で初期化されたまま
    // 更新されず、**保存済みのフォントが効いているのに入力欄だけ空**になる。
    // 読み込み結果が届いたら空欄のときだけ追いつかせる（入力中の値は壊さない）。
    if (_controller.text.isEmpty && fontFamily.isNotEmpty) {
      _controller.value = TextEditingValue(
        text: fontFamily,
        selection: TextSelection.collapsed(offset: fontFamily.length),
      );
    }
    final previewStyle = TextStyle(
      fontSize: 15,
      fontFamily: fontFamily.isEmpty ? null : fontFamily,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('投稿本文のフォント', style: TextStyle(fontSize: 16)),
          const SizedBox(height: 4),
          Text(
            '投稿画面の本文入力に使う等幅フォントを、端末にインストール済みの'
            'ファミリ名で指定します（例: HackGen Console）。空欄で既定に戻ります。'
            '全角が半角のちょうど 2 倍幅になるデュアルワイド等幅フォントで最も'
            '効果があります',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            decoration: const InputDecoration(
              hintText: 'フォントファミリ名（空欄＝既定）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (value) => ref
                .read(composeFontFamilyProvider.notifier)
                .setFontFamily(value),
          ),
          const SizedBox(height: 8),
          // ライブプレビュー。デュアルワイド等幅なら全角 5 字と半角 10 字が同じ
          // 幅で揃う。silent フォールバックのため、効いたか一目で分かるように。
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.outline.withValues(alpha: 0.5),
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('あいうえお｜ABC\nABCDEFGHIJ｜012', style: previewStyle),
          ),
        ],
      ),
    );
  }
}

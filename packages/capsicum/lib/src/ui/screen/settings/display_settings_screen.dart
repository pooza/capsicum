import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../platform/platform_info.dart';
import '../../../provider/account_manager_provider.dart';
import '../../../provider/preferences_provider.dart';
import '../../../service/update_checker.dart';

class DisplaySettingsScreen extends ConsumerWidget {
  const DisplaySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hideLivecure = ref.watch(hideLivecureProvider);
    final absoluteTime = ref.watch(absoluteTimeProvider);
    final blurAllImages = ref.watch(blurAllImagesProvider);
    final hideInstanceTicker = ref.watch(hideInstanceTickerProvider);
    final previewCardMode = ref.watch(previewCardModeProvider);
    final mulukhiya = ref.watch(currentMulukhiyaProvider);
    final nowPlayingUrlProvider = ref.watch(nowPlayingUrlProviderProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('表示'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('絶対時間で表示'),
            subtitle: const Text('投稿日時を「3分前」ではなく「2026-03-26 12:34」形式で表示します'),
            value: absoluteTime,
            onChanged: (_) => ref.read(absoluteTimeProvider.notifier).toggle(),
          ),
          SwitchListTile(
            title: const Text('すべての画像をぼかす'),
            subtitle: const Text('NSFW フラグに関係なくすべての画像をぼかし表示にします。タップで個別に表示できます'),
            value: blurAllImages,
            onChanged: (_) => ref.read(blurAllImagesProvider.notifier).toggle(),
          ),
          SwitchListTile(
            title: const Text('投稿元サーバー帯を隠す'),
            subtitle: const Text(
              'リモート投稿に表示される投稿元サーバー名／テーマカラー帯（インスタンスティッカー）を非表示にします',
            ),
            value: hideInstanceTicker,
            onChanged: (_) =>
                ref.read(hideInstanceTickerProvider.notifier).toggle(),
          ),
          ListTile(
            title: const Text('プレビューカード（OGP）'),
            subtitle: Text(_previewCardModeLabel(previewCardMode)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showPreviewCardModeDialog(context, ref),
          ),
          // ナウプレ URL の優先プロバイダ (#681)。URL を持たない源 (Apple Music /
          // MPRIS / SMTC) を enrich (#669) で URL 解決する際、Apple Music /
          // Spotify どちらの URL を載せるかの端末共通 (アカウント非依存) 嗜好。
          // enrich が使える (`nowplayingResolverEnabled`) サーバーのアカウントを
          // 現在選択しているときだけ表示する（enrich が走らなければ効かない）。
          if (mulukhiya?.nowplayingResolverEnabled ?? false)
            ListTile(
              title: const Text('ナウプレの URL 優先プロバイダ'),
              subtitle: Text(
                '再生中の曲に URL を補完するとき、'
                '${_nowPlayingUrlProviderLabel(nowPlayingUrlProvider)} の URL を優先',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showNowPlayingUrlProviderDialog(context, ref),
            ),
          SwitchListTile(
            title: const Text('投稿前に確認する'),
            subtitle: const Text('すべての投稿操作で送信前に確認ダイアログを表示します'),
            value: ref.watch(confirmBeforePostProvider),
            onChanged: (_) =>
                ref.read(confirmBeforePostProvider.notifier).toggle(),
          ),
          SwitchListTile(
            title: const Text('カスタム絵文字を隙間なく並べる'),
            subtitle: const Text(
              'カスタム絵文字の間に見える余白をなくします（「ゼロ幅スペース」を使用、Mastodon のみ）',
            ),
            value: ref.watch(emojiZeroWidthSpaceProvider),
            onChanged: (_) =>
                ref.read(emojiZeroWidthSpaceProvider.notifier).toggle(),
          ),
          SwitchListTile(
            title: const Text('#実況 タグの投稿を非表示'),
            subtitle: const Text('実況中の投稿をタイムラインから隠します'),
            value: hideLivecure,
            onChanged: (_) => ref.read(hideLivecureProvider.notifier).toggle(),
          ),
          SwitchListTile(
            title: const Text('起動時に既読位置を復元'),
            subtitle: const Text(
              'オンにすると前回読んでいた位置から、オフにすると常に最新の投稿から'
              'ホームのタイムラインを開きます（Mastodon のみ）',
            ),
            value: ref.watch(restoreReadPositionProvider),
            onChanged: (_) =>
                ref.read(restoreReadPositionProvider.notifier).toggle(),
          ),
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

  String _nowPlayingUrlProviderLabel(NowPlayingUrlProvider provider) {
    return switch (provider) {
      NowPlayingUrlProvider.appleMusic => 'Apple Music',
      NowPlayingUrlProvider.spotify => 'Spotify',
    };
  }

  void _showNowPlayingUrlProviderDialog(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('ナウプレの URL 優先プロバイダ'),
        children: [
          RadioGroup<NowPlayingUrlProvider>(
            groupValue: ref.watch(nowPlayingUrlProviderProvider),
            onChanged: (value) {
              if (value != null) {
                ref
                    .read(nowPlayingUrlProviderProvider.notifier)
                    .setProvider(value);
                Navigator.pop(context);
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final provider in NowPlayingUrlProvider.values)
                  RadioListTile<NowPlayingUrlProvider>(
                    title: Text(_nowPlayingUrlProviderLabel(provider)),
                    value: provider,
                    dense: true,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _previewCardModeLabel(PreviewCardMode mode) {
    return switch (mode) {
      PreviewCardMode.show => '表示',
      PreviewCardMode.blur => '画像をぼかす',
      PreviewCardMode.hide => '非表示',
    };
  }

  void _showPreviewCardModeDialog(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('プレビューカード（OGP）'),
        children: [
          RadioGroup<PreviewCardMode>(
            groupValue: ref.watch(previewCardModeProvider),
            onChanged: (value) {
              if (value != null) {
                ref.read(previewCardModeProvider.notifier).setMode(value);
                Navigator.pop(context);
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in PreviewCardMode.values)
                  RadioListTile<PreviewCardMode>(
                    title: Text(_previewCardModeLabel(mode)),
                    value: mode,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

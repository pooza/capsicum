import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';
import '../../model/account.dart';
import '../../url_helper.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/hashtag_provider.dart';
import '../../provider/list_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../provider/supporter_purchase_provider.dart';
import '../../provider/timeline_provider.dart';
import '../util/about_dialog.dart';
import '../util/post_scope_display.dart';
import 'desktop_menu_model.dart';

/// デスクトップメニューの /（Ctrl+R）の「タイムラインを更新」から、現在表示中の
/// タイムライン（HomeScreen）のリフレッシュを呼ぶためのコールバック登録口 (#834)。
/// HomeScreen がマウント中に自身の _refreshCurrentTimeline を登録し、Shell 上の
/// メニューはこれを読み出して呼ぶ。未登録なら no-op。
final desktopTimelineRefreshProvider = StateProvider<Future<void> Function()?>(
  (ref) => null,
);

/// ドロワーと macOS グローバルメニュー (#712) を同一ソースで駆動するための
/// ナビゲーション項目モデル。feature-gate と動的リストを 1 箇所で評価し、
/// `Drawer` の `ListTile` と `PlatformMenuBar` の項目を両方ここから生成することで、
/// メニューを別実装してドロワーと乖離するのを防ぐ（issue の「設計の肝」）。
class HomeNavItem {
  final String title;
  final IconData icon;

  /// 0 なら非表示。お知らせの未読件数バッジ等に使う。
  final int badge;

  /// デスクトップメニュー (#712/#841) に割り当てるショートカット。null なら無し。
  /// 主修飾キー（mac=Cmd / win-linux=Ctrl）は [MenuShortcut] が吸収する。ドロワーの
  /// `ListTile` では使わない（モバイルにメニューショートカットは無い）。
  final MenuShortcut? shortcut;

  /// 項目選択時のアクション。ドロワー経由ではドロワーを閉じてから、メニュー
  /// 経由ではそのまま呼ばれる（呼び分けは生成側の `onActivate` で吸収）。
  final VoidCallback onSelected;

  const HomeNavItem({
    required this.title,
    required this.icon,
    this.badge = 0,
    this.shortcut,
    required this.onSelected,
  });
}

const timelineLabels = {
  TimelineType.home: 'ホーム',
  TimelineType.local: 'ローカル',
  TimelineType.social: 'ソーシャル',
  TimelineType.federated: 'グローバル',
};

/// Mastodon uses "連合" instead of "グローバル".
const mastodonLabelOverrides = {TimelineType.federated: '連合'};

String tabLabel(
  WidgetRef ref,
  TabType tab,
  bool isMastodon,
  DecentralizedBackendAdapter? adapter,
  List<PostList> allLists,
) {
  return switch (tab) {
    TimelineTab(:final type) => () {
      if (type == TimelineType.local) {
        return ref.watch(localTimelineNameProvider);
      }
      return (isMastodon ? mastodonLabelOverrides[type] : null) ??
          timelineLabels[type] ??
          (type == TimelineType.directMessages
              ? postScopeLabel(PostScope.direct, adapter)
              : type.name);
    }(),
    ListTab(:final id, :final name) =>
      name ?? allLists.where((l) => l.id == id).firstOrNull?.title ?? id,
    HashtagTab(:final tag) => hashtagSpecLabel(tag),
    ChannelTab(:final id, :final name) => name ?? id,
    NotificationsTab() => '通知',
    AnnouncementsTab() => 'お知らせ',
    MessagesTab() => 'メッセージ',
  };
}

/// Persist the currently selected tab to SharedPreferences.
void saveLastTab(WidgetRef ref) {
  final account = ref.read(currentAccountProvider);
  if (account == null) return;
  final storageKey = account.key.toStorageKey();
  final tab = ref.read(selectedTabProvider);
  ref.read(lastTabProvider(storageKey).notifier).save(tab.toKey());
}

/// ドロワー / メニュー共通のナビゲーション項目を 1 箇所で構築する (#712)。
/// feature-gate（adapter の各 Support）とモロヘイヤ有無をここで評価する。
/// [announcementsShownAsTab] はお知らせがタブとして可視のときに true で、
/// その場合ドロワー / メニューからは「お知らせ」項目を出さない（重複回避）。
/// [onActivate] はドロワー経由のとき `dismiss`（ドロワーを閉じる）を渡す。
List<HomeNavItem> buildHomeNavItems(
  BuildContext context,
  WidgetRef ref,
  Account? current,
  AccountManagerState accountState,
  int unreadAnnouncements,
  bool announcementsShownAsTab, {
  VoidCallback? onActivate,
}) {
  final adapter = ref.read(currentAdapterProvider);
  final hasMulukhiya = ref.read(currentMulukhiyaProvider) != null;
  void act(VoidCallback action) {
    onActivate?.call();
    action();
  }

  return [
    HomeNavItem(
      title: '検索',
      icon: Icons.search,
      shortcut: const MenuShortcut(LogicalKeyboardKey.keyF),
      onSelected: () => act(() => context.push('/search')),
    ),
    HomeNavItem(
      title: '通知',
      icon: Icons.notifications_outlined,
      onSelected: () => act(() => context.push('/notifications')),
    ),
    if (accountState.accounts.length > 1)
      HomeNavItem(
        title: 'すべての通知',
        icon: Icons.notifications_active_outlined,
        onSelected: () => act(() => context.push('/notifications/all')),
      ),
    HomeNavItem(
      title: adapter is ReactionSupport ? 'お気に入り' : 'ブックマーク',
      icon: Icons.bookmark_outline,
      onSelected: () => act(() => context.push('/bookmarks')),
    ),
    if (!announcementsShownAsTab)
      HomeNavItem(
        title: 'お知らせ',
        icon: Icons.campaign_outlined,
        badge: unreadAnnouncements,
        onSelected: () => act(() => context.push('/announcements')),
      ),
    if (adapter is ListSupport)
      HomeNavItem(
        title: 'リスト',
        icon: Icons.list,
        onSelected: () => act(() => showListChooser(context, ref)),
      ),
    if (adapter is ChannelSupport)
      HomeNavItem(
        title: 'チャンネル',
        icon: Icons.forum,
        onSelected: () => act(() => showChannelList(context, ref)),
      ),
    if (adapter is ChatSupport && (adapter as ChatSupport).canReadChat)
      HomeNavItem(
        title: 'メッセージ',
        icon: Icons.chat_bubble_outline,
        onSelected: () => act(() => context.push('/chat')),
      ),
    if (adapter is DriveSupport)
      HomeNavItem(
        title: 'ドライブ',
        icon: Icons.cloud_outlined,
        onSelected: () => act(() => context.push('/drive')),
      ),
    if (adapter is ClipSupport)
      HomeNavItem(
        title: 'クリップ',
        icon: Icons.content_paste,
        onSelected: () => act(() => showClipList(context, ref)),
      ),
    if (adapter is AntennaSupport)
      HomeNavItem(
        title: 'アンテナ',
        icon: Icons.settings_input_antenna,
        onSelected: () => act(() => showAntennaList(context, ref)),
      ),
    if (adapter is FlashSupport)
      HomeNavItem(
        title: 'Play',
        icon: Icons.play_circle_outline,
        onSelected: () => act(() => showFlashList(context, ref)),
      ),
    if (adapter is GallerySupport)
      HomeNavItem(
        title: 'ギャラリー',
        icon: Icons.photo_library_outlined,
        onSelected: () => act(() => context.push('/gallery')),
      ),
    if (adapter is PagesSupport)
      HomeNavItem(
        title: 'ページ',
        icon: Icons.article_outlined,
        onSelected: () => act(() => context.push('/pages')),
      ),
    if (hasMulukhiya) ...[
      HomeNavItem(
        title: 'プロフィールタグ',
        icon: Icons.tag,
        onSelected: () => act(() => showFavoriteTags(context, ref)),
      ),
      HomeNavItem(
        title: 'リンク',
        icon: Icons.link,
        onSelected: () => act(() => showServerLinks(context, ref)),
      ),
      HomeNavItem(
        title: 'メディアカタログ',
        icon: Icons.photo_library_outlined,
        onSelected: () => act(() => context.push('/media-catalog')),
      ),
    ],
    if (adapter is ScheduleSupport)
      HomeNavItem(
        title: '予約投稿',
        icon: Icons.schedule,
        onSelected: () => act(() => context.push('/scheduled')),
      ),
    if (adapter is DraftSupport)
      HomeNavItem(
        title: '下書き',
        icon: Icons.edit_note,
        onSelected: () => act(() => context.push('/drafts')),
      ),
    // 投稿テンプレート管理 (#767)。テンプレ機能提供サーバーのみ。
    if (ref.read(currentMulukhiyaProvider)?.composeTemplatesEnabled == true)
      HomeNavItem(
        title: '投稿テンプレート',
        icon: Icons.description_outlined,
        onSelected: () => act(() => context.push('/templates/manage')),
      ),
    HomeNavItem(
      title: 'サーバー情報',
      icon: Icons.dns_outlined,
      onSelected: () => act(() => context.push('/server-info')),
    ),
    HomeNavItem(
      title: '設定',
      icon: Icons.settings,
      onSelected: () => act(() => context.push('/settings')),
    ),
  ];
}

/// ログアウト確認ダイアログ。ドロワーと macOS メニュー (#712) の両方から
/// 呼ぶため切り出す。
Future<void> confirmLogout(
  BuildContext context,
  WidgetRef ref,
  Account current,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('ログアウト'),
      content: Text(
        '@${current.user.username}@${current.key.host} '
        'からログアウトしますか？',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('キャンセル'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('ログアウト'),
        ),
      ],
    ),
  );

  if (confirmed == true) {
    await ref.read(accountManagerProvider.notifier).logout(current);
  }
}

/// デスクトップメニューの単一モデル (#841)。macOS の native メニュー
/// ([renderMacMenuBar]) と Windows/Linux の in-window メニュー
/// ([renderInWindowMenuBar]) の両方をこの 1 箇所の定義から生成し、項目の二重
/// 管理を解消する。ドロワーと同じ [buildHomeNavItems] を「移動」の単一ソースにする。
/// 「設定」は先頭 capsicum メニューにあるため「移動」からは除外する（従来
/// in-window だけで行っていた除外をモデルへ一本化し、macOS の二重表示も解消）。
/// 編集項目は OS 提供型が無いので、現在フォーカス中の EditableText へ text-editing
/// intent を dispatch して再現する。
List<MenuSubmenuEntry> buildDesktopMenuModel(
  BuildContext context,
  WidgetRef ref,
  Account? current,
  AccountManagerState accountState,
  int unreadAnnouncements,
) {
  final announcementsShownAsTab =
      current != null &&
      ref.watch(
        isTabVisibleProvider((
          storageKey: current.key.toStorageKey(),
          tab: const AnnouncementsTab(),
        )),
      );
  final navItems = buildHomeNavItems(
    context,
    ref,
    current,
    accountState,
    unreadAnnouncements,
    announcementsShownAsTab,
  );
  final otherAccounts = accountState.accounts
      .where((a) => a.key != current?.key)
      .toList();

  // 表示メニューのタブ切替・実況トグル (#841)。タブ列・現在タブ・ラベルは
  // タブバー (_buildTimelineTabs) と同じ provider / tabLabel を単一ソースに使う。
  final adapter = ref.watch(currentAdapterProvider);
  final isMastodon =
      adapter != null &&
      !adapter.capabilities.supportedTimelines.contains(TimelineType.social);
  final storageKey = current?.key.toStorageKey();
  final visibleTabs = storageKey != null
      ? ref.watch(visibleTabsProvider(storageKey))
      : const <TabType>[];
  final allLists = ref.watch(listsProvider).valueOrNull ?? const <PostList>[];
  final currentTab = ref.watch(selectedTabProvider);
  final hideLivecure = ref.watch(hideLivecureProvider);

  // 編集アクションは現在フォーカス中のフィールドへ intent を送る。フォーカスが
  // テキスト以外なら no-op（intent を処理する Action が無い）。
  void editAction(Intent intent) {
    final focusCtx = FocusManager.instance.primaryFocus?.context;
    if (focusCtx != null) Actions.maybeInvoke(focusCtx, intent);
  }

  return [
    MenuSubmenuEntry(
      // 先頭メニューは macOS ではアプリ名（capsicum）で表示される。in-window は
      // ブランドの唐辛子アイコンを見出しに付ける。
      label: 'capsicum',
      leadingIcon: Image.asset(
        'assets/images/capsicum_icon.webp',
        width: 18,
        height: 18,
      ),
      children: [
        MenuActionEntry(
          label: 'capsicum について',
          icon: Icons.info_outline,
          onSelected: () => showAboutCapsicum(context),
        ),
        MenuActionEntry(
          label: '設定',
          icon: Icons.settings,
          shortcut: const MenuShortcut(LogicalKeyboardKey.comma),
          globalShortcut: true,
          onSelected: () => context.push('/settings'),
        ),
        // 投げ銭（サポート）への導線 (#853)。IAP 提供プラットフォームのみ。
        // デスクトップでの露出を上げる狙い。
        if (ref.watch(supporterEntryVisibleProvider))
          MenuActionEntry(
            label: 'capsicum をサポート…',
            icon: Icons.volunteer_activism_outlined,
            onSelected: () => context.push('/settings/supporter'),
          ),
        const MenuGroupSeparator(),
        const MenuProvidedEntry(
          macType: PlatformProvidedMenuItemType.servicesSubmenu,
        ),
        const MenuGroupSeparator(),
        const MenuProvidedEntry(macType: PlatformProvidedMenuItemType.hide),
        const MenuProvidedEntry(
          macType: PlatformProvidedMenuItemType.hideOtherApplications,
        ),
        const MenuProvidedEntry(
          macType: PlatformProvidedMenuItemType.showAllApplications,
        ),
        const MenuGroupSeparator(),
        const MenuProvidedEntry(macType: PlatformProvidedMenuItemType.quit),
      ],
    ),
    MenuSubmenuEntry(
      label: '編集',
      children: [
        MenuActionEntry(
          label: '取り消す',
          icon: Icons.undo,
          shortcut: const MenuShortcut(LogicalKeyboardKey.keyZ),
          onSelected: () =>
              editAction(const UndoTextIntent(SelectionChangedCause.keyboard)),
        ),
        MenuActionEntry(
          label: 'やり直す',
          icon: Icons.redo,
          shortcut: const MenuShortcut(LogicalKeyboardKey.keyZ, shift: true),
          onSelected: () =>
              editAction(const RedoTextIntent(SelectionChangedCause.keyboard)),
        ),
        MenuActionEntry(
          label: 'カット',
          icon: Icons.content_cut,
          shortcut: const MenuShortcut(LogicalKeyboardKey.keyX),
          onSelected: () => editAction(
            const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
          ),
        ),
        MenuActionEntry(
          label: 'コピー',
          icon: Icons.content_copy,
          shortcut: const MenuShortcut(LogicalKeyboardKey.keyC),
          onSelected: () => editAction(CopySelectionTextIntent.copy),
        ),
        MenuActionEntry(
          label: 'ペースト',
          icon: Icons.content_paste,
          shortcut: const MenuShortcut(LogicalKeyboardKey.keyV),
          onSelected: () =>
              editAction(const PasteTextIntent(SelectionChangedCause.keyboard)),
        ),
        MenuActionEntry(
          label: 'すべて選択',
          icon: Icons.select_all,
          shortcut: const MenuShortcut(LogicalKeyboardKey.keyA),
          onSelected: () => editAction(
            const SelectAllTextIntent(SelectionChangedCause.keyboard),
          ),
        ),
      ],
    ),
    MenuSubmenuEntry(
      label: '移動',
      children: [
        // 新規投稿は頻用アクションなので先頭に置き、⌘N/Ctrl+N を割り当てる。
        MenuActionEntry(
          label: '新規投稿',
          icon: Icons.edit_outlined,
          shortcut: const MenuShortcut(LogicalKeyboardKey.keyN),
          globalShortcut: true,
          onSelected: () => context.push('/compose'),
        ),
        const MenuGroupSeparator(),
        for (final item in navItems.where((i) => i.title != '設定'))
          MenuActionEntry(
            label: item.title,
            icon: item.icon,
            badge: item.badge,
            shortcut: item.shortcut,
            // shortcut を持つナビ項目（検索 ⌘F 等）は in-window でも発火させる。
            globalShortcut: item.shortcut != null,
            onSelected: item.onSelected,
          ),
      ],
    ),
    if (accountState.accounts.isNotEmpty)
      MenuSubmenuEntry(
        label: 'アカウント',
        children: [
          if (current != null)
            MenuActionEntry(
              label: 'プロフィール',
              icon: Icons.person_outline,
              onSelected: () => context.push('/profile', extra: current.user),
            ),
          if (current != null && otherAccounts.isNotEmpty)
            const MenuGroupSeparator(),
          for (final a in otherAccounts)
            MenuActionEntry(
              label: '@${a.user.username}@${a.key.host}',
              icon: Icons.switch_account,
              onSelected: () {
                ref.read(accountManagerProvider.notifier).switchAccount(a);
                // 常駐メニュー (#834) は /compose 等の状態を持つ画面上でも切替
                // できる。旧アカウントの本文・reply/renote/draft ID が残ったまま
                // 新アカウントの adapter で投稿/下書き削除される事故を防ぐため、
                // 切替時はアカウントスコープの clean な /home へ戻す（#880 Codex P1）。
                context.go('/home');
              },
            ),
          const MenuGroupSeparator(),
          MenuActionEntry(
            label: 'アカウントを追加',
            icon: Icons.person_add_alt,
            onSelected: () => context.push('/server'),
          ),
          if (current != null)
            MenuActionEntry(
              label: 'ログアウト',
              icon: Icons.logout,
              onSelected: () => confirmLogout(context, ref, current),
            ),
        ],
      ),
    MenuSubmenuEntry(
      label: '表示',
      children: [
        MenuActionEntry(
          label: 'タイムラインを更新',
          icon: Icons.refresh,
          shortcut: const MenuShortcut(LogicalKeyboardKey.keyR),
          globalShortcut: true,
          onSelected: () async {
            final cb = ref.read(desktopTimelineRefreshProvider);
            if (cb != null) await cb();
          },
        ),
        const MenuGroupSeparator(),
        // 表示中のタブへ切り替える。現在タブに ✓（mac はラベル末尾・in-window は
        // 先頭アイコン）。ラベルはタブバーと同じ [tabLabel] を単一ソースに使う。
        if (visibleTabs.isNotEmpty)
          MenuSubmenuEntry(
            label: 'タブ',
            children: [
              for (final tab in visibleTabs)
                MenuActionEntry(
                  label: tabLabel(ref, tab, isMastodon, adapter, allLists),
                  checked: tab is! MessagesTab && tab == currentTab,
                  onSelected: () {
                    // MessagesTab はフィードを持たず /chat に push する
                    // 遷移トリガー (#439)。selectedTab は切り替えない。
                    if (tab is MessagesTab) {
                      context.push('/chat');
                      return;
                    }
                    ref.read(selectedTabProvider.notifier).state = tab;
                    saveLastTab(ref);
                    // 設定・投稿など push した画面からタブを選んだ場合も、
                    // 切り替えたタブのタイムラインを見せるためホームへ戻す
                    // (#841)。既にホームなら実質 no-op。
                    context.go('/home');
                  },
                ),
            ],
          ),
        // 実況（#実況 タグ投稿）の表示トグル。表示中に ✓。
        MenuActionEntry(
          label: '実況を表示',
          checked: !hideLivecure,
          onSelected: () => ref.read(hideLivecureProvider.notifier).toggle(),
        ),
        const MenuGroupSeparator(),
        MenuProvidedEntry(
          macType: PlatformProvidedMenuItemType.toggleFullScreen,
          inWindowLabel: '全画面表示を切り替え',
          inWindowIcon: Icons.fullscreen,
          inWindowAction: () async {
            final full = await windowManager.isFullScreen();
            await windowManager.setFullScreen(!full);
          },
        ),
      ],
    ),
    MenuSubmenuEntry(
      label: 'ウインドウ',
      children: [
        MenuProvidedEntry(
          macType: PlatformProvidedMenuItemType.minimizeWindow,
          inWindowLabel: '最小化',
          inWindowIcon: Icons.minimize,
          inWindowAction: () => windowManager.minimize(),
        ),
        MenuProvidedEntry(
          macType: PlatformProvidedMenuItemType.zoomWindow,
          inWindowLabel: '最大化',
          inWindowIcon: Icons.crop_square,
          inWindowAction: () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
        ),
      ],
    ),
  ];
}

Future<void> showFavoriteTags(BuildContext context, WidgetRef ref) async {
  final mulukhiya = ref.read(currentMulukhiyaProvider);
  if (mulukhiya == null) return;

  try {
    final tags = await mulukhiya.getFavoriteTags();
    if (tags.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('プロフィールタグはありません')));
      }
      return;
    }
    if (!context.mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'プロフィールタグ',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final tag in tags)
              ListTile(
                leading: const Icon(Icons.tag, size: 20),
                title: Text('#${tag.name}'),
                trailing: Text(
                  '${tag.count}人',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                dense: true,
                onTap: () {
                  Navigator.pop(context);
                  context.push('/hashtag/${tag.name}');
                },
              ),
          ],
        ),
      ),
    );
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('プロフィールタグの取得に失敗しました')));
    }
  }
}

Future<void> showServerLinks(BuildContext context, WidgetRef ref) async {
  final mulukhiya = ref.read(currentMulukhiyaProvider);
  final account = ref.read(currentAccountProvider);
  if (mulukhiya == null || account == null) return;

  final host = account.key.host;
  final groups = await mulukhiya.getLinks(host);
  if (groups.isEmpty) return;
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('リンク', style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final group in groups) ...[
            if (group.title != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Text(
                  group.title!,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            for (final link in group.links)
              ListTile(
                leading: const Icon(Icons.open_in_new, size: 20),
                title: Text(link.body),
                dense: true,
                onTap: () {
                  Navigator.pop(context);
                  final url = link.href.startsWith('/')
                      ? Uri.parse('https://$host${link.href}')
                      : Uri.parse(link.href);
                  launchUrlSafely(url);
                },
              ),
          ],
        ],
      ),
    ),
  );
}

Future<void> showFlashList(BuildContext context, WidgetRef ref) async {
  final adapter = ref.read(currentAdapterProvider);
  if (adapter is! FlashSupport) return;

  final List<Flash> flashes;
  try {
    flashes = await (adapter as FlashSupport).getFeaturedFlashes();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Play の取得に失敗しました')));
    }
    return;
  }
  if (flashes.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Play はありません')));
    }
    return;
  }
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Play', style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final flash in flashes)
            ListTile(
              leading: const Icon(Icons.play_circle_outline, size: 20),
              title: Text(flash.title),
              subtitle: flash.summary != null && flash.summary!.isNotEmpty
                  ? Text(
                      flash.summary!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    )
                  : null,
              dense: true,
              onTap: () {
                // #830 でネイティブ実行に切り替えた。以前は外部ブラウザで
                // /play/<id> を開いていた (#73)。実行できない Play は
                // 詳細画面側で「ブラウザで開く」に degrade する。
                Navigator.pop(context);
                context.push('/play', extra: {'flash': flash});
              },
            ),
        ],
      ),
    ),
  );
}

Future<void> showClipList(BuildContext context, WidgetRef ref) async {
  final adapter = ref.read(currentAdapterProvider);
  if (adapter is! ClipSupport) return;

  final List<NoteClip> clips;
  try {
    clips = await (adapter as ClipSupport).getClips();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('クリップの取得に失敗しました')));
    }
    return;
  }
  if (clips.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('クリップはありません')));
    }
    return;
  }
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('クリップ', style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final clip in clips)
            ListTile(
              leading: const Icon(Icons.content_paste, size: 20),
              title: Text(clip.name),
              subtitle: clip.description != null && clip.description!.isNotEmpty
                  ? Text(
                      clip.description!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : null,
              dense: true,
              onTap: () {
                Navigator.pop(context);
                context.push('/clip/${clip.id}', extra: clip.name);
              },
            ),
        ],
      ),
    ),
  );
}

Future<void> showAntennaList(BuildContext context, WidgetRef ref) async {
  final adapter = ref.read(currentAdapterProvider);
  if (adapter is! AntennaSupport) return;

  final List<Antenna> antennas;
  try {
    antennas = await (adapter as AntennaSupport).getAntennas();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('アンテナの取得に失敗しました')));
    }
    return;
  }
  if (antennas.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('アンテナはありません')));
    }
    return;
  }
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('アンテナ', style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final antenna in antennas)
            ListTile(
              leading: const Icon(Icons.settings_input_antenna, size: 20),
              title: Text(antenna.name),
              dense: true,
              onTap: () {
                Navigator.pop(context);
                context.push('/antenna/${antenna.id}', extra: antenna.name);
              },
            ),
        ],
      ),
    ),
  );
}

/// リストのクイックチューザ（#805）。保存済みリストを 1 つ選んで、その
/// タイムライン画面（`/list/:id`）へ飛ぶ。作成/編集/メンバー管理は末尾の
/// 「リストを管理」から `/lists/manage` へ温存する。
Future<void> showListChooser(BuildContext context, WidgetRef ref) async {
  final adapter = ref.read(currentAdapterProvider);
  if (adapter is! ListSupport) return;

  final List<PostList> lists;
  try {
    lists = await (adapter as ListSupport).getLists();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('リストの取得に失敗しました')));
    }
    return;
  }
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('リスト', style: Theme.of(context).textTheme.titleMedium),
          ),
          if (lists.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('リストはありません'),
            )
          else
            for (final list in lists)
              ListTile(
                leading: const Icon(Icons.list, size: 20),
                title: Text(list.title),
                dense: true,
                onTap: () {
                  Navigator.pop(context);
                  context.push('/list/${list.id}', extra: list.title);
                },
              ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.settings, size: 20),
            title: const Text('リストを管理'),
            dense: true,
            onTap: () {
              Navigator.pop(context);
              context.push('/lists/manage');
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> showChannelList(BuildContext context, WidgetRef ref) async {
  final adapter = ref.read(currentAdapterProvider);
  if (adapter is! ChannelSupport) return;

  final List<Channel> channels;
  try {
    channels = await (adapter as ChannelSupport).getFollowedChannels();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('チャンネルの取得に失敗しました。再ログインが必要な場合があります')),
      );
    }
    return;
  }
  if (channels.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('フォロー中のチャンネルはありません')));
    }
    return;
  }
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'チャンネル',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final ch in channels)
            ListTile(
              leading: const Icon(Icons.forum, size: 20),
              title: Text(ch.name),
              dense: true,
              onTap: () {
                Navigator.pop(context);
                context.push('/channel/${ch.id}', extra: ch.name);
              },
            ),
        ],
      ),
    ),
  );
}

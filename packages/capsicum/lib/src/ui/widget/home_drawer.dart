import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../constants.dart';
import '../../model/account.dart';
import '../../model/offline_account.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../provider/supporter_purchase_provider.dart';
import '../../provider/unread_badge_provider.dart';
import '../util/about_dialog.dart';
import '../util/deck_navigation.dart';
import '../util/mouse_drag_scroll_behavior.dart';
import '../util/offline_account_display.dart';
import 'emoji_text.dart';
import 'home_menu.dart';
import 'server_badge.dart';
import 'user_avatar.dart';

/// タブ表示のドロワー。デッキ画面からも同じものを開く (#1272)。
///
/// 以前は `home_screen.dart` の中に閉じていた（`_buildDrawer`）。中身は動かして
/// おらず、タブ表示の見た目は変えていない。
///
/// ⚠⚠ **ウィジェットにせず、呼び出し側の [context] と [ref] で組む。**項目の
/// 多くは、ドロワーを閉じたあとに `ref` を使う（ログアウトの確認 → 実行・
/// リストの選択など）。ドロワーの子として独立した `ConsumerWidget` にすると、
/// 閉じるアニメーションが終わった時点で `ref` が捨てられ、確認ダイアログの
/// あとの処理が落ちる。
///
/// [inDeck] はデッキ画面から開くとき (#1272・2026-10-11 pooza):
///
/// - **アカウントの切り替えを出さない。**デッキでは、現在のアカウントが変わると
///   カラムのコンテナの割り当てが組み替わる（`docs/deck-ui-decisions.md`
///   決定済み事項 8 / 11）。メニューバーが「他アカウントへ切り替え」を隠すのと
///   同じ扱い。追加・ログアウト・未接続アカウントの復帰は残す。
/// - 「デッキ」「検索」「通知」の項目は出さない（[buildHomeNavItems] の側）。
///
/// [columnContext] は、選ぶとタイムラインになる項目（リスト・チャンネル・
/// プロフィールタグ）をカラムで開くための `context` を返す（デッキだけが渡す）。
/// ⚠ 関数で受けるのは、ドロワーの中身が組まれる時点（＝開いた時点）の値を
/// 使うため。この関数が呼ばれる時点では、まだ無いことがある。
Widget buildHomeDrawer(
  BuildContext context,
  WidgetRef ref,
  Account? current,
  AccountManagerState accountState,
  int unreadAnnouncements, {
  bool wideLayout = false,
  bool inDeck = false,
  BuildContext? Function()? columnContext,
}) {
  final otherAccounts = inDeck
      ? const <Account>[]
      : accountState.accounts.where((a) => a.key != current?.key).toList();

  // Drawer 内の各 ListTile から `Scaffold.of(context).closeDrawer()` を
  // 呼ぶ際、`context` は buildHomeDrawer が受け取る画面レベルの
  // 外側 context のため、Scaffold ancestor が見つからず assertion で
  // 落ちる (#541 リグレッション、ca98c21 で本格化)。Builder を 1 段
  // 挟んで Drawer サブツリー内側の `innerCtx` を取得し、それを使う
  // `dismiss()` を closure ローカルに用意して全 ListTile から呼ぶ。
  // wide モード (Scaffold.drawer が null、Row で並ぶ inline 配置) でも
  // Scaffold.of は親 Scaffold を見つけられるが、その Scaffold に
  // drawer が無いため `closeDrawer()` 自体が hasDrawer ガードで no-op。
  // Drawer 内 ListView をマウスドラッグでスクロールできるよう、設定 ON
  // 時のみ ScrollBehavior を override (#574)。タブ列と同じ取り回し。
  final mouseDragEnabled = ref.watch(mouseDragScrollProvider);
  return Drawer(
    // 常駐 (wide) モードでは Row 内の左パネルとして並ぶため、Material
    // 既定の内容側 (右端) 角丸を消してフラットな仕切りにする (#541
    // フォローアップ)。オーバーレイ (narrow) モードでは shape: null で
    // 従来の Material 既定 (角丸あり) を維持する。
    shape: wideLayout ? const RoundedRectangleBorder() : null,
    child: Builder(
      builder: (innerCtx) {
        void dismiss() => Scaffold.of(innerCtx).closeDrawer();
        // お知らせがタブとして可視なら、ドロワー / メニューの「お知らせ」項目は
        // 出さない（重複回避）。ref.watch でタブ可視の切替に追従する。
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
          onActivate: dismiss,
          inDeck: inDeck,
          columnContext: columnContext?.call(),
        );
        // ドロワーは `Scaffold.drawer` で body ではないため、#1037 の
        // `BottomSafeArea` が掛かっていない。padding を 0 のままにすると
        // 末尾のフッター（サーバー情報と capsicum の版番号）がナビゲーション
        // バーの下に入り、**最下部までスクロールしても逃がせない** (#1058)。
        // 3 ボタンナビはバーが不透明なので版番号が完全に隠れる。
        //
        // ⚠ **包むのではなく padding で足す。**`SafeArea` で包むとリストの
        // ビューポート自体が縮み、スクロール中の項目がバーの手前で切れて
        // ドロワーの地色が帯で残る。上端のヘッダーが `SafeArea(bottom: false)`
        // を内側に持ちつつ背景は全面に伸びているのと同じ扱いに揃える。
        //
        // ⚠ ヘッダーの `SafeArea` は自分の子から padding を取り除くだけで、
        // ここの `MediaQuery` は消費しない。二重には入らない。
        final list = ListView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(innerCtx).bottom,
          ),
          children: [
            Container(
              color: Theme.of(context).colorScheme.primaryContainer,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: SafeArea(
                bottom: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: current != null
                          ? () {
                              dismiss();
                              openProfile(context, current.user);
                            }
                          : null,
                      child: current != null
                          ? UserAvatar(
                              user: current.user,
                              size: 72,
                              borderRadius: 8,
                            )
                          : Container(
                              width: 72,
                              height: 72,
                              color: Theme.of(context).colorScheme.primary,
                              alignment: Alignment.center,
                              child: const Text(
                                '?',
                                style: TextStyle(
                                  fontSize: 24,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: current != null
                          ? () {
                              dismiss();
                              openProfile(context, current.user);
                            }
                          : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          EmojiText(
                            current?.user.displayName ??
                                current?.user.username ??
                                '',
                            emojis: current?.user.emojis ?? const {},
                            fallbackHost: current?.user.host,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '@${current?.user.username ?? ""}@${current?.key.host ?? ""}',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (current != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: ServerBadge.fromHost(
                                current.key.host,
                                themeColors: ref.watch(hostThemeColorProvider),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (otherAccounts.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  'アカウント切替',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              ...otherAccounts.map((account) {
                final themeColors = ref.watch(hostThemeColorProvider);
                final badges = ref.watch(unreadBadgeProvider).valueOrNull;
                final badge = badges?[account.key.toStorageKey()];
                return ListTile(
                  leading: Badge(
                    isLabelVisible: badge != null && badge.hasUnread,
                    label: badge != null && badge.hasUnread
                        ? Text('${badge.total}')
                        : null,
                    child: UserAvatar(
                      user: account.user,
                      size: 32,
                      compact: true,
                    ),
                  ),
                  title: EmojiText(
                    account.user.displayName ?? account.user.username,
                    emojis: account.user.emojis,
                    fallbackHost: account.user.host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '@${account.user.username}@${account.key.host}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: ServerBadge.fromHost(
                          account.key.host,
                          themeColors: themeColors,
                        ),
                      ),
                    ],
                  ),
                  onTap: () {
                    ref
                        .read(accountManagerProvider.notifier)
                        .switchAccount(account);
                    dismiss();
                  },
                );
              }),
            ],
            // 到達不能でオフライン保持中のアカウント (#792)。消さずに greyed で
            // 一覧へ残す。タップ / 再試行アイコンで即時再試行し、復帰すれば通常
            // アカウントへ昇格。サーバーがドメインごと消えて戻る見込みが無い
            // 場合はゴミ箱で端末から削除できる。
            // 未接続（secret 消失）と到達不能（オフライン）は**復帰手段が
            // 違う** (#967)。前者は待っても戻らないのでログインへ送り、
            // 「再試行」ボタンも出さない。後者は従来どおり再試行。
            if (accountState.offlineAccounts.isNotEmpty)
              ...accountState.offlineAccounts.map((offline) {
                final disabledColor = Theme.of(context).disabledColor;
                final needsLogin = !offline.recoverableByRetry;
                void reconnect() {
                  dismiss();
                  // ログイン先のサーバーを埋めた状態で開く。ユーザーが
                  // ホスト名を打ち直さずに済む。
                  context.push(reconnectRouteFor(offline.key));
                }

                return ListTile(
                  leading: Icon(
                    needsLogin ? Icons.link_off : Icons.person_off_outlined,
                    color: disabledColor,
                  ),
                  title: Text(
                    offline.handle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: disabledColor),
                  ),
                  subtitle: Text(
                    needsLogin
                        ? disconnectedAccountSubtitle
                        : offline.retrying
                        ? '接続できません（再試行中…）'
                        : '接続できません（自動再試行中）',
                    style: TextStyle(color: disabledColor),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 未接続に「再試行」は出さない。押しても必ず失敗する。
                      if (!needsLogin)
                        IconButton(
                          icon: Icon(Icons.refresh, color: disabledColor),
                          tooltip: '再試行',
                          onPressed: () {
                            ref
                                .read(accountManagerProvider.notifier)
                                .retryOfflineRestores();
                            dismiss();
                          },
                        ),
                      if (needsLogin)
                        IconButton(
                          icon: Icon(Icons.login, color: disabledColor),
                          tooltip: '接続し直す',
                          onPressed: reconnect,
                        ),
                      IconButton(
                        icon: Icon(Icons.delete_outline, color: disabledColor),
                        tooltip: 'このアカウントを削除',
                        onPressed: () =>
                            confirmRemoveOfflineAccount(context, ref, offline),
                      ),
                    ],
                  ),
                  onTap: () {
                    if (needsLogin) {
                      reconnect();
                      return;
                    }
                    ref
                        .read(accountManagerProvider.notifier)
                        .retryOfflineRestores();
                    dismiss();
                  },
                );
              }),
            ListTile(
              leading: const Icon(Icons.person_add),
              title: const Text('アカウントを追加'),
              onTap: () {
                dismiss();
                context.push('/server');
              },
            ),
            const Divider(),
            // ナビゲーション項目は _buildNavItems を単一ソースに生成する
            // (#712)。drawer と macOS グローバルメニューで同じ feature-gate /
            // 動的リストを共有し、メニューとの乖離を防ぐ。
            ...navItems.map(
              (item) => ListTile(
                leading: Icon(item.icon),
                title: Text(item.title),
                trailing: item.badge > 0
                    ? Badge(label: Text('${item.badge}'))
                    : null,
                onTap: item.onSelected,
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('ログアウト'),
              onTap: () {
                dismiss();
                if (current == null) return;
                confirmLogout(context, ref, current);
              },
            ),
            // 投げ銭（サポート）導線 (#853)。以前は「設定」内にあったが投げ銭は
            // 設定ではないためドロワー下部（「capsicum について」の上）へ出す。
            // 表示条件は設定内と同じ [supporterEntryVisibleProvider]（IAP 提供
            // プラットフォーム＋ Web 支援を案内する Linux / #893）。
            if (ref.watch(supporterEntryVisibleProvider))
              ListTile(
                leading: Image.asset(
                  AppConstants.supporterIconAsset,
                  width: 24,
                  height: 24,
                ),
                title: const Text('capsicum をサポート'),
                subtitle: const Text('投げ銭で開発と通知リレーを応援'),
                onTap: () {
                  dismiss();
                  context.push('/settings/supporter');
                },
              ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('capsicum について'),
              onTap: () async {
                dismiss();
                if (!context.mounted) return;
                await showAboutCapsicum(context);
              },
            ),
            const Divider(),
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const SizedBox.shrink();
                final info = snapshot.data!;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (current != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '${current.key.host} (${current.key.type.displayName})'
                            '${current.softwareVersion != null ? ' v${current.softwareVersion}' : ''}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                          ),
                        ),
                      Text(
                        'capsicum v${info.version} (${info.buildNumber})',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        );
        return mouseDragEnabled
            ? ScrollConfiguration(
                behavior: const MouseDragScrollBehavior(),
                child: list,
              )
            : list;
      },
    ),
  );
}

/// オフライン保持中のアカウントを、確認ダイアログ付きで端末から削除する
/// (#792)。ドロワーの切替リストとオフラインプレースホルダの両方から使う。
/// サーバーがドメインごと消えて復帰見込みが無いアカウントの片付け用。
Future<void> confirmRemoveOfflineAccount(
  BuildContext context,
  WidgetRef ref,
  OfflineAccount offline,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('アカウントを削除'),
      content: Text(
        '${offline.handle} をこの端末から削除します。'
        'サーバーが復帰しても自動では戻らず、再ログインが必要になります。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('削除'),
        ),
      ],
    ),
  );
  if (ok == true) {
    await ref
        .read(accountManagerProvider.notifier)
        .removeOfflineAccount(offline.key);
  }
}

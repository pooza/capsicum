import 'dart:async';
import 'dart:io';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../../main.dart' show appLaunchStopwatch;
import '../../model/account.dart';
import '../../model/offline_account.dart';
import '../../url_helper.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/announcement_provider.dart';
import '../../provider/hashtag_provider.dart';
import '../../provider/list_provider.dart';
import '../../provider/marker_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../../util/startup_trace.dart';
import '../util/about_dialog.dart';
import '../util/mouse_drag_scroll_behavior.dart';
import '../util/post_scope_display.dart';
import '../../provider/timeline_provider.dart';
import '../../provider/unread_badge_provider.dart';
import '../../provider/update_check_provider.dart';
import '../../service/update_checker.dart';
import '../widget/emoji_text.dart';
import '../widget/server_badge.dart';
import '../widget/user_avatar.dart';
import '../widget/post_tile.dart';
import '../widget/simple_post_bar.dart';
import '../widget/tab_management_sheet.dart';
import 'announcement_screen.dart';
import 'channel_timeline_screen.dart';
import 'notification_screen.dart';

/// Convenience providers derived from [selectedTabProvider] for backward
/// compatibility with widgets that only need to know the selected list or
/// hashtag.
final selectedListProvider = Provider<PostList?>((ref) {
  final tab = ref.watch(selectedTabProvider);
  if (tab is! ListTab) return null;
  final lists = ref.watch(listsProvider).valueOrNull ?? [];
  return lists.where((l) => l.id == tab.id).firstOrNull;
});

final selectedHashtagProvider = Provider<String?>((ref) {
  final tab = ref.watch(selectedTabProvider);
  return tab is HashtagTab ? tab.tag : null;
});

/// ドロワーと macOS グローバルメニュー (#712) を同一ソースで駆動するための
/// ナビゲーション項目モデル。feature-gate と動的リストを 1 箇所で評価し、
/// `Drawer` の `ListTile` と `PlatformMenuBar` の項目を両方ここから生成することで、
/// メニューを別実装してドロワーと乖離するのを防ぐ（issue の「設計の肝」）。
class HomeNavItem {
  final String title;
  final IconData icon;

  /// 0 なら非表示。お知らせの未読件数バッジ等に使う。
  final int badge;

  /// macOS グローバルメニュー (#712) に割り当てるショートカット。null なら無し。
  /// ドロワーの `ListTile` では使わない（モバイルにメニューショートカットは無い）。
  final MenuSerializableShortcut? shortcut;

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

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  bool _markerRestored = false;
  bool _lastTabRestored = false;
  String? _lastTabRestoredForAccount;
  String? _pendingListRestore;
  Timer? _throttleTimer;
  bool _showScrollTop = false;
  // pull-to-refresh 実行中だけ true。文脈切替（アカウント/タブ切替）の reload と
  // 区別し、リフレッシュ中は現データを残す（リスト消失を防ぐ）ため (#758)。
  bool _pullRefreshing = false;

  @override
  void initState() {
    super.initState();
    _itemPositionsListener.itemPositions.addListener(_onPositionsChanged);
  }

  @override
  void dispose() {
    _itemPositionsListener.itemPositions.removeListener(_onPositionsChanged);
    _throttleTimer?.cancel();
    super.dispose();
  }

  void _onPositionsChanged() {
    // Throttle to avoid excessive processing.
    if (_throttleTimer?.isActive ?? false) return;
    _throttleTimer = Timer(const Duration(milliseconds: 200), () {});

    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;

    // Load more when near the end.
    final selectedHashtag = ref.read(selectedHashtagProvider);
    final selectedList = ref.read(selectedListProvider);
    final TimelineState? timeline;
    if (selectedHashtag != null) {
      timeline = ref.read(hashtagTimelineProvider(selectedHashtag)).valueOrNull;
    } else if (selectedList != null) {
      timeline = ref.read(listTimelineProvider(selectedList.id)).valueOrNull;
    } else {
      timeline = ref.read(timelineProvider).valueOrNull;
    }
    // 継続エラー時 (loadMoreError) は自動再試行を止め、リトライストームで末尾の
    // ローディングが固化するのを防ぐ (#678)。回復は pull-to-refresh / タブ再選択で
    // build() が再実行され loadMoreError がクリアされたとき。
    if (timeline != null &&
        !timeline.isLoadingMore &&
        timeline.loadMoreError == null) {
      final maxIndex = positions
          .map((p) => p.index)
          .reduce((a, b) => a > b ? a : b);
      if (maxIndex >= timeline.posts.length - 8) {
        if (selectedHashtag != null) {
          ref
              .read(hashtagTimelineProvider(selectedHashtag).notifier)
              .loadMore();
        } else if (selectedList != null) {
          ref.read(listTimelineProvider(selectedList.id).notifier).loadMore();
        } else {
          ref.read(timelineProvider.notifier).loadMore();
        }
      }
    }

    // Show/hide scroll-to-top button.
    final minIndex = positions
        .map((p) => p.index)
        .reduce((a, b) => a < b ? a : b);
    final shouldShow = minIndex > 1;
    if (shouldShow != _showScrollTop) {
      setState(() => _showScrollTop = shouldShow);
    }

    // Notify timeline notifier whether the user is near the top so that
    // streaming posts can be queued while scrolling (#296).
    if (selectedHashtag == null && selectedList == null) {
      ref.read(timelineProvider.notifier).setNearTop(minIndex <= 1);
    }

    // Save marker (home timeline only, debounced).
    if (selectedList == null && selectedHashtag == null) {
      final selectedType = ref.read(selectedTimelineTypeProvider);
      if (selectedType == TimelineType.home && timeline != null) {
        if (minIndex < timeline.posts.length) {
          ref.read(homeMarkerSaverProvider).save(timeline.posts[minIndex].id);
        }
      }
    }
  }

  Future<void> _restoreMarker(List<Post> posts) async {
    if (_markerRestored) return;
    _markerRestored = true;

    // 既読位置復元をオフにしているユーザーは常に最新先頭で開く (#715)。
    if (!ref.read(restoreReadPositionProvider)) return;

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! MarkerSupport) return;

    // #716 計測: 既読位置復元は first paint の後に走る別系統コスト
    // (getMarkers 往復＋古い位置への jumpTo)。所要・命中可否を残し、
    // startup.home_timeline (restore_read_position タグ付き) と突き合わせて
    // 「未読位置読み込みあり」の体感への寄与を切り分ける。
    final markerSw = Stopwatch()..start();
    var found = false;
    var jumped = false;
    try {
      final markers = await (adapter as MarkerSupport).getMarkers();
      markerSw.stop();
      if (markers.home == null) return;

      final markerId = markers.home!.lastReadId;
      final index = posts.indexWhere((p) => p.id == markerId);
      found = index >= 0;
      if (index > 0 && mounted && _itemScrollController.isAttached) {
        _itemScrollController.jumpTo(index: index);
        jumped = true;
      }
    } catch (_) {
      // Marker fetch failed — silently ignore.
    } finally {
      if (markerSw.isRunning) markerSw.stop();
      _reportMarkerRestore(
        markerMs: markerSw.elapsedMilliseconds,
        found: found,
        jumped: jumped,
      );
    }
  }

  /// 既読位置復元 (#715) の所要を起動計測に残す (#716)。first paint 後に走る
  /// ため startup.home_timeline には含まれない別系統コスト。getMarkers の往復
  /// (transaction duration = marker_ms)・マーカーが読み込み済みページ内にあったか
  /// (found)・実際に jump したか (jumped) を持ち、未読位置読み込みの体感寄与を
  /// 切り分ける。
  void _reportMarkerRestore({
    required int markerMs,
    required bool found,
    required bool jumped,
  }) {
    final sinceLaunchMs = appLaunchStopwatch.elapsedMilliseconds;
    debugPrint(
      'capsicum: startup: marker restore (getMarkers) in ${markerMs}ms '
      '(since_launch=${sinceLaunchMs}ms found=$found jumped=$jumped)',
    );
    recordStartupPhase(
      'app.startup.marker_restore',
      durationMs: markerMs,
      measurementsMs: {'since_launch_ms': sinceLaunchMs},
      tags: {'found': '$found', 'jumped': '$jumped'},
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(currentAccountProvider);
    final accountState = ref.watch(accountManagerProvider);

    // オンラインで使えるアカウントが 1 つも無く、到達不能でオフライン保持中の
    // アカウントだけがある状態（サーバー停止 / 再構築中）。ログイン画面へ戻さず
    // 「接続できません／再試行中」を表示し、復帰したら自動でタイムラインへ戻る
    // (#792)。
    if (account == null && accountState.offlineAccounts.isNotEmpty) {
      return const _OfflineHomeScaffold();
    }

    final selectedType = ref.watch(selectedTimelineTypeProvider);
    final selectedList = ref.watch(selectedListProvider);
    final selectedHashtag = ref.watch(selectedHashtagProvider);
    final unreadAnnouncements = ref.watch(unreadAnnouncementCountProvider);

    // External entry points (notification taps etc.) may request a specific
    // initial tab. Applying it suppresses the saved last-tab restore on cold
    // start so the requested focus does not get overwritten, and also works
    // when HomeScreen is already mounted.
    final pendingTab = ref.watch(pendingInitialTabProvider);
    if (pendingTab != null) {
      _lastTabRestored = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(selectedTabProvider.notifier).state = pendingTab;
        ref.read(pendingInitialTabProvider.notifier).state = null;
      });
    }

    // Restore last selected tab once the saved value arrives from disk.
    // Reset when the active account changes so each account gets its own tab.
    if (account != null) {
      final storageKey = account.key.toStorageKey();
      if (_lastTabRestoredForAccount != storageKey) {
        _lastTabRestoredForAccount = storageKey;
        _pendingListRestore = null;
        // 外部経路で pendingTab が要求されている場合（通知タップ等）は
        // そちらを優先する。_lastTabRestored は pendingTab 分岐で既に true。
        // そうでないケースだけ「home へリセット」のフォールバックを走らせる
        // が、その後到着する lastTab（sync / async 双方）が先に走っていたら
        // スキップする guard を postFrame 側に入れる。
        if (pendingTab == null) {
          _lastTabRestored = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            // lastTab が sync/async で復元されていれば home にリセットしない
            // （アカウント間往復時に保存タブを失わないため）。
            if (_lastTabRestored) return;
            ref.read(selectedTabProvider.notifier).state = const TimelineTab(
              TimelineType.home,
            );
          });
        }
      }
      if (!_lastTabRestored) {
        ref.listen(lastTabProvider(storageKey), (prev, next) {
          if (!_lastTabRestored && next != null) {
            _lastTabRestored = true;
            _applyLastTab(next);
          }
        });
        // Also check synchronously in case the value was already loaded.
        // build 中に selectedTabProvider を書き換えると Riverpod の
        // `_debugCanModifyProviders` assertion で例外になるため、
        // d08897c (#281 latent fix) と同じく postFrame に延期する (#386)。
        final saved = ref.read(lastTabProvider(storageKey));
        if (!_lastTabRestored && saved != null) {
          _lastTabRestored = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _applyLastTab(saved);
          });
        }
      }
    }

    // Deferred list tab restore: apply once listsProvider finishes loading.
    if (_pendingListRestore != null) {
      ref.listen(listsProvider, (prev, next) {
        final pendingId = _pendingListRestore;
        if (pendingId == null) return;
        final lists = next.valueOrNull ?? [];
        final list = lists.where((l) => l.id == pendingId).firstOrNull;
        if (list != null) {
          _pendingListRestore = null;
          ref.read(selectedTabProvider.notifier).state = ListTab(
            id: list.id,
            name: list.title,
          );
        }
      });
    }

    // Choose which timeline data to display.
    final AsyncValue<TimelineState> timeline;
    if (selectedHashtag != null) {
      timeline = ref.watch(hashtagTimelineProvider(selectedHashtag));
    } else if (selectedList != null) {
      timeline = ref.watch(listTimelineProvider(selectedList.id));
    } else {
      timeline = ref.watch(timelineProvider);
    }

    // Provider to listen for loadMore errors.
    final ProviderListenable<AsyncValue<TimelineState>> listenTarget;
    if (selectedHashtag != null) {
      listenTarget = hashtagTimelineProvider(selectedHashtag);
    } else if (selectedList != null) {
      listenTarget = listTimelineProvider(selectedList.id);
    } else {
      listenTarget = timelineProvider;
    }

    // Show a SnackBar when loadMore fails.
    ref.listen(listenTarget, (prev, next) {
      final error = next.valueOrNull?.loadMoreError;
      if (error != null && prev?.valueOrNull?.loadMoreError == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('読み込みに失敗しました'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    });

    // streaming 再接続上限到達時に silent failure にならないよう SnackBar
    // 表示 (#602)。#784 で give-up せず自動再試行を続けるため「停止」ではなく
    // 「不安定・自動再接続中（引けば即時）」と伝える。フラグは live 復帰時
    // (timeline_provider) と pull-to-refresh / タブ再選択の build() でクリアされる。
    ref.listen(listenTarget, (prev, next) {
      final exhausted = next.valueOrNull?.streamReconnectExhausted ?? false;
      final prevExhausted =
          prev?.valueOrNull?.streamReconnectExhausted ?? false;
      if (exhausted && !prevExhausted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('ライブ更新が不安定です。自動で再接続中（下に引くと即時再接続）'),
              duration: Duration(seconds: 5),
            ),
          );
        }
      }
    });

    // REST ページ取得上限到達 (フィルタで全件除外) を SnackBar 表示 (#624)。
    // streamReconnectExhausted と同じく false → true 遷移時に出し、
    // pull-to-refresh / タブ再選択の build() でクリアされる。
    ref.listen(listenTarget, (prev, next) {
      final capHit = next.valueOrNull?.pageCapHit ?? false;
      final prevCapHit = prev?.valueOrNull?.pageCapHit ?? false;
      if (capHit && !prevCapHit) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('フィルタで多くの投稿が除外されています。条件を見直すと表示されるかもしれません'),
              duration: Duration(seconds: 5),
            ),
          );
        }
      }
    });

    // 直配チャネル (Linux AppImage / Windows 自己署名 MSIX) の新版検知を
    // SnackBar で控えめに通知し、Release ページへの導線を出す (#641)。
    // FutureProvider が AsyncLoading → AsyncData(UpdateInfo) に遷移した
    // タイミングを拾うので、起動時に 1 回だけ出る。ストアビルド (= dart-
    // define DIRECT_CHANNEL 未指定) や設定 OFF では provider が `null`
    // を即返すため何も起きない。
    ref.listen<AsyncValue<UpdateInfo?>>(updateCheckProvider, (prev, next) {
      final info = next.valueOrNull;
      if (info == null) return;
      if (prev?.valueOrNull?.latestVersion == info.latestVersion) return;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('新しいバージョン v${info.latestVersion} があります'),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: 'リリースページ',
            onPressed: () => launchUrlSafely(info.releaseUrl),
          ),
        ),
      );
    });

    // 画面幅 >= 900px なら左ドロワーを常駐させる (#541)。閾値は実況用途で
    // 「タイムライン本体 (約 600px) + ドロワー 304px」が成り立つ最小ラインを
    // 採用。タブレット横向き (iPad 1024 / Galaxy Tab 1280) や 13" デスクトップ
    // (1366+) も常駐側に倒れる。ハンバーガーは AppBar.leading: null + Drawer
    // 内 `Scaffold.of(context).closeDrawer()` が hasDrawer ガード内蔵で no-op
    // になることを利用して、wide / narrow 双方を 1 つの _buildDrawer 実装で
    // 賄う。未読アナウンスメントの badge は Drawer 内の「お知らせ」ListTile に
    // 既に trailing badge があるため AppBar 側を消しても可視性は失われない。
    final wideLayout = MediaQuery.of(context).size.width >= 900;
    final drawerWidget = _buildDrawer(
      context,
      ref,
      account,
      accountState,
      unreadAnnouncements,
      wideLayout: wideLayout,
    );

    final scaffold = Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: wideLayout
            ? null
            : Builder(
                builder: (context) => IconButton(
                  icon: Badge(
                    isLabelVisible: unreadAnnouncements > 0,
                    child: const Icon(Icons.menu),
                  ),
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ),
        title: Row(
          children: [
            if (account != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => context.push('/profile', extra: account.user),
                  child: UserAvatar(
                    user: account.user,
                    size: 28,
                    borderRadius: 4,
                  ),
                ),
              ),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  EmojiText(
                    account?.user.displayName ?? account?.user.username ?? '',
                    emojis: account?.user.emojis ?? const {},
                    fallbackHost: account?.user.host,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (account != null)
                    _buildServerBadge(context, ref, account.key.host),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // actions の IconButton 既定 48px タップ枠を詰めてタイトル幅を稼ぐ
          // (簡易投稿バーと同じコンパクト枠 / #614)。1 つの IconButtonTheme で
          // 包めば、_LivecureFilterButton 等カスタムウィジェット内部の
          // IconButton にも効く。Row(min) で間隔も詰める。
          IconButtonTheme(
            data: IconButtonThemeData(
              style: IconButton.styleFrom(
                minimumSize: const Size(36, 40),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ライブ更新の接続インジケータ (#714)。streaming する本線 TL
                // (home / local / social / federated) のタブを開いているときだけ
                // 出す。以前は「ハッシュタグでない ∧ リストでない ∧ DM でない」の
                // 消去法だったため、お知らせ / 通知 / チャンネル / メッセージの
                // 各タブ (TimelineTab でない or 別購読) を素通りさせ、表示中の
                // 内容と無関係な裏のホーム購読状態を出していた (#793)。現在の
                // タブが本線 TimelineTab か否かを積極判定して直す。
                if (ref.watch(selectedTabProvider) case TimelineTab(
                  :final type,
                ) when type != TimelineType.directMessages)
                  const _StreamStatusIndicator(),
                _LivecureFilterButton(ref: ref),
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () => context.push('/search'),
                ),
                // Hide notification bell when notifications tab is visible.
                if (account == null ||
                    !ref.watch(
                      isTabVisibleProvider((
                        storageKey: account.key.toStorageKey(),
                        tab: const NotificationsTab(),
                      )),
                    ))
                  _NotificationBellButton(
                    hasMultipleAccounts: accountState.accounts.length > 1,
                  ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: _buildTimelineTabs(context),
        ),
      ),
      drawer: wideLayout ? null : drawerWidget,
      floatingActionButton: _showScrollTop
          ? Padding(
              padding: const EdgeInsets.only(bottom: 56),
              child: FloatingActionButton.small(
                onPressed: () {
                  if (!_itemScrollController.isAttached) return;
                  _itemScrollController.scrollTo(
                    index: 0,
                    duration: const Duration(milliseconds: 300),
                  );
                },
                tooltip: '先頭へ',
                child: const Icon(Icons.arrow_upward),
              ),
            )
          : null,
      body: wideLayout
          ? Row(
              children: [
                // 常駐モードでも _buildDrawer が返す Drawer ウィジェットを
                // そのまま流用 (Drawer は Material + elevation のスタイリングを
                // 内包しているため、Row 内に直接置いても境界線とシャドウで
                // 自然に左パネルになる)。
                drawerWidget,
                Expanded(
                  child: _buildBody(
                    ref.watch(selectedTabProvider),
                    selectedList,
                    selectedType,
                    selectedHashtag,
                    timeline,
                  ),
                ),
              ],
            )
          : _buildBody(
              ref.watch(selectedTabProvider),
              selectedList,
              selectedType,
              selectedHashtag,
              timeline,
            ),
    );

    // macOS のみグローバルメニューバーをミラーする (#712)。Windows / Linux の
    // in-window メニューは後続 #713。
    if (Platform.isMacOS) {
      return _buildMacMenuBar(
        context,
        scaffold,
        account,
        accountState,
        unreadAnnouncements,
      );
    }
    return scaffold;
  }

  Widget _buildBody(
    TabType currentTab,
    PostList? selectedList,
    TimelineType selectedType,
    String? selectedHashtag,
    AsyncValue<dynamic> timeline,
  ) {
    // スワイプによるカラム移動はタブ種別に依存しない共通操作なので、
    // 通知 / お知らせ / リスト等すべてのタブ本体を単一の GestureDetector で
    // 包む。HitTestBehavior.opaque で空リスト領域上のドラッグも拾う (#573)。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: _onSwipe,
      child: _buildTabContent(
        currentTab,
        selectedList,
        selectedType,
        selectedHashtag,
        timeline,
      ),
    );
  }

  Widget _buildTabContent(
    TabType currentTab,
    PostList? selectedList,
    TimelineType selectedType,
    String? selectedHashtag,
    AsyncValue<dynamic> timeline,
  ) {
    // Non-timeline tabs: render their dedicated views.
    if (currentTab is NotificationsTab) return const NotificationView();
    if (currentTab is AnnouncementsTab) return const AnnouncementView();
    // MessagesTab はフィードを持たず、タップ時に /chat へ push する遷移
    // トリガー (#439)。アクティブ化されないようタップ側で intercept する
    // 想定だが、保存された状態の食い違い等で到達した場合は防御的に空表示。
    if (currentTab is MessagesTab) return const SizedBox.shrink();
    if (currentTab is ChannelTab) {
      // アカウント切替で ChannelSupport を持たない adapter (Mastodon 等) に
      // 移った直後、selectedTabProvider が前アカウントの ChannelTab を
      // 保持していることがある (#461)。タブバー側は visibleTabsProvider の
      // capability check で除外されるが、selectedTab の値がここに到達する
      // 場合は通常タイムライン経路にフォールスルーさせて整合を取る。
      final adapter = ref.watch(currentAdapterProvider);
      if (adapter is ChannelSupport) {
        return ChannelTimelineView(
          key: ValueKey('channel:${currentTab.id}'),
          channelId: currentTab.id,
          channelName: currentTab.name,
        );
      }
    }
    final account = ref.watch(currentAccountProvider);
    final storageKey = account?.key.toStorageKey();
    final bgPath = storageKey != null
        ? ref.watch(backgroundImageProvider(storageKey))
        : null;
    final bgOpacity = storageKey != null
        ? ref.watch(backgroundOpacityProvider(storageKey))
        : defaultBackgroundOpacity;

    // 現在の文脈（アカウント＋タブ種別/タグ/リスト）の contextKey。watch している
    // provider の state が別文脈で取得した「前のキャッシュ」を保持していると、
    // この期待キーと state.contextKey が食い違う。その間はローディングへ落とす
    // (#758)。
    final expectedContextKey = account == null
        ? null
        : timelineContextKey(
            account.key,
            selectedHashtag != null
                ? 'tag:$selectedHashtag'
                : selectedList != null
                ? 'list:${selectedList.id}'
                : 'tl:${selectedType.name}',
          );

    // 文脈切替（アカウント / タブ / ハッシュタグ / リスト変更）で TL をロード中
    // は、直前文脈の TL（前のアカウントの投稿など）をそのまま残さずローディングを
    // 出す。Riverpod は再計算中も valueOrNull に直前値を保持し、さらに account→
    // adapter→timeline の dirty 伝播が HomeScreen の再 build より遅れることがある
    // ため、isLoading 判定だけでは「前の文脈の値（しかも isLoading=false）」を
    // 取りこぼす。そこで state.contextKey が現在の期待キーと食い違う＝前文脈の
    // キャッシュなら、isLoading の有無に関わらずローディングへ落とす（同一アカウント
    // 内のタブ切替でも前 TL を出さない、#758）。stale 判定は接続インジケータの色
    // (_StreamStatusIndicator) と同じ [_timelineIsStale] を共有して drift を防ぐ
    // (#764)。ただし pull-to-refresh（_pullRefreshing）は現データを残す（リスト
    // 消失を防ぐ・RefreshIndicator が自前のスピナーを出す）。
    final showingStale =
        (timeline.isLoading ||
            _timelineIsStale(timeline, expectedContextKey)) &&
        !_pullRefreshing;
    final effectiveTimeline = showingStale
        ? const AsyncValue<TimelineState>.loading()
        : timeline;

    Widget body = Column(
      children: [
        Expanded(
          child: effectiveTimeline.when(
            data: (tlState) {
              // Restore marker position on first load (home timeline only).
              if (selectedList == null &&
                  selectedType == TimelineType.home &&
                  tlState.posts.isNotEmpty) {
                _restoreMarker(tlState.posts);
              }
              return RefreshIndicator(
                onRefresh: () async {
                  _markerRestored = false;
                  // リフレッシュ中は上の isLoading 判定でローディングへ落とさず現
                  // データを残す。完了で必ず戻す。
                  setState(() => _pullRefreshing = true);
                  try {
                    final Future<TimelineState> refreshed;
                    if (selectedHashtag != null) {
                      refreshed = ref.refresh(
                        hashtagTimelineProvider(selectedHashtag).future,
                      );
                    } else if (selectedList != null) {
                      refreshed = ref.refresh(
                        listTimelineProvider(selectedList.id).future,
                      );
                    } else {
                      refreshed = ref.refresh(timelineProvider.future);
                    }
                    await refreshed;
                  } finally {
                    if (mounted) {
                      setState(() => _pullRefreshing = false);
                    }
                  }
                },
                child: ScrollablePositionedList.separated(
                  itemScrollController: _itemScrollController,
                  itemPositionsListener: _itemPositionsListener,
                  itemCount:
                      tlState.posts.length + (tlState.isLoadingMore ? 1 : 0),
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    if (index >= tlState.posts.length) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    return PostTile(post: tlState.posts[index]);
                  },
                ),
              );
            },
            loading: () {
              if (_showScrollTop) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() => _showScrollTop = false);
                });
              }
              return const Center(child: CircularProgressIndicator());
            },
            error: (error, stack) {
              final message = _timelineErrorMessage(error);
              final canRetry = !_isForbiddenError(error);
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(message, textAlign: TextAlign.center),
                      if (canRetry) ...[
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () {
                            if (selectedList != null) {
                              ref.invalidate(
                                listTimelineProvider(selectedList.id),
                              );
                            } else {
                              ref.invalidate(timelineProvider);
                            }
                          },
                          child: const Text('再試行'),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SimplePostBar(),
      ],
    );

    if (bgPath != null) {
      body = Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: FileImage(File(bgPath)),
            fit: BoxFit.cover,
            opacity: bgOpacity,
          ),
        ),
        child: body,
      );
    }

    return body;
  }

  void _onSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 300) return;

    final account = ref.read(currentAccountProvider);
    if (account == null) return;
    final storageKey = account.key.toStorageKey();
    final visible = ref.read(visibleTabsProvider(storageKey));
    final currentTab = ref.read(selectedTabProvider);
    final index = visible.indexOf(currentTab);
    if (index < 0) return;

    final next = velocity < 0 ? index + 1 : index - 1;
    if (next < 0 || next >= visible.length) return;

    ref.read(selectedTabProvider.notifier).state = visible[next];
    _saveLastTab();
  }

  /// Persist the currently selected tab to SharedPreferences.
  void _saveLastTab() {
    final account = ref.read(currentAccountProvider);
    if (account == null) return;
    final storageKey = account.key.toStorageKey();
    final tab = ref.read(selectedTabProvider);
    ref.read(lastTabProvider(storageKey).notifier).save(tab.toKey());
  }

  void _applyLastTab(String saved) {
    final tab = TabType.fromKey(saved);
    if (tab == null) return;

    switch (tab) {
      case TimelineTab(:final type):
        final adapter = ref.read(currentAdapterProvider);
        final supported =
            adapter?.capabilities.supportedTimelines ??
            {TimelineType.home, TimelineType.local, TimelineType.federated};
        if (supported.contains(type)) {
          ref.read(selectedTabProvider.notifier).state = tab;
        }
      case ListTab(:final id):
        final lists = ref.read(listsProvider).valueOrNull ?? [];
        if (lists.any((l) => l.id == id)) {
          ref.read(selectedTabProvider.notifier).state = tab;
        } else {
          _pendingListRestore = id;
        }
      case HashtagTab(:final tag):
        final account = ref.read(currentAccountProvider);
        if (account != null) {
          final config = ref.read(
            tabConfigProvider(account.key.toStorageKey()),
          );
          if (config.any(
            (e) => e.tab is HashtagTab && (e.tab as HashtagTab).tag == tag,
          )) {
            ref.read(selectedTabProvider.notifier).state = tab;
          }
        }
      case ChannelTab(:final id):
        final account = ref.read(currentAccountProvider);
        if (account != null) {
          final config = ref.read(
            tabConfigProvider(account.key.toStorageKey()),
          );
          if (config.any(
            (e) => e.tab is ChannelTab && (e.tab as ChannelTab).id == id,
          )) {
            ref.read(selectedTabProvider.notifier).state = tab;
          }
        }
      case NotificationsTab():
      case AnnouncementsTab():
        ref.read(selectedTabProvider.notifier).state = tab;
      case MessagesTab():
        // MessagesTab はフィードを持たず、push notification 等から飛んで
        // きた場合も /chat に直接遷移する。selectedTab は変更しない。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.push('/chat');
        });
    }
  }

  static bool _isForbiddenError(Object error) {
    if (error is DioException) {
      return error.response?.statusCode == 403;
    }
    return false;
  }

  static String _timelineErrorMessage(Object error) {
    if (_isForbiddenError(error)) {
      return 'このサーバーではこのタイムラインが利用できません';
    }
    return 'タイムラインの読み込みに失敗しました';
  }

  static const _timelineLabels = {
    TimelineType.home: 'ホーム',
    TimelineType.local: 'ローカル',
    TimelineType.social: 'ソーシャル',
    TimelineType.federated: 'グローバル',
  };

  /// Mastodon uses "連合" instead of "グローバル".
  static const _mastodonLabelOverrides = {TimelineType.federated: '連合'};

  Widget _buildTimelineTabs(BuildContext context) {
    final adapter = ref.watch(currentAdapterProvider);
    final isMastodon =
        adapter != null &&
        !(adapter.capabilities.supportedTimelines.contains(
          TimelineType.social,
        ));

    final account = ref.watch(currentAccountProvider);
    final storageKey = account?.key.toStorageKey();
    final visible = storageKey != null
        ? ref.watch(visibleTabsProvider(storageKey))
        : <TabType>[const TimelineTab(TimelineType.home)];
    final currentTab = ref.watch(selectedTabProvider);

    // Resolve list names for ListTab entries.
    final allLists = ref.watch(listsProvider).valueOrNull ?? [];

    // マウスドラッグでタブ列を掴んで横スクロールできるよう、設定 ON 時のみ
    // ScrollBehavior を override (#574)。OFF (default) はトラックパッド
    // 2 本指スワイプの既存挙動を維持。
    final mouseDragEnabled = ref.watch(mouseDragScrollProvider);
    final tabsScroll = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          ...visible.map((tab) {
            final label = _tabLabel(tab, isMastodon, adapter, allLists);
            // MessagesTab はフィードを持たず /chat に push する遷移トリガー
            // (#439)。タップでも selectedTabProvider を切り替えない (= 戻った
            // ときに元のタブが活きている)。
            final isSelected = tab is! MessagesTab && tab == currentTab;
            return _tabChip(context, label, isSelected, () {
              if (tab is MessagesTab) {
                context.push('/chat');
                return;
              }
              ref.read(selectedTabProvider.notifier).state = tab;
              _saveLastTab();
            });
          }),
          // Tab management button.
          IconButton(
            icon: const Icon(Icons.tune, size: 20),
            tooltip: 'タブ管理',
            padding: const EdgeInsets.symmetric(horizontal: 8),
            constraints: const BoxConstraints(),
            onPressed: () => _showTabManagement(context),
          ),
        ],
      ),
    );
    return mouseDragEnabled
        ? ScrollConfiguration(
            behavior: const MouseDragScrollBehavior(),
            child: tabsScroll,
          )
        : tabsScroll;
  }

  String _tabLabel(
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
        return (isMastodon ? _mastodonLabelOverrides[type] : null) ??
            _timelineLabels[type] ??
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

  void _showTabManagement(BuildContext context) {
    final account = ref.read(currentAccountProvider);
    if (account == null) return;
    final storageKey = account.key.toStorageKey();
    final adapter = ref.read(currentAdapterProvider);
    final isMastodon =
        adapter != null &&
        !(adapter.capabilities.supportedTimelines.contains(
          TimelineType.social,
        ));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          TabManagementSheet(storageKey: storageKey, isMastodon: isMastodon),
    );
  }

  Widget _tabChip(
    BuildContext context,
    String label,
    bool isSelected,
    VoidCallback onTap,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isSelected ? colorScheme.primary : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  /// ドロワー / メニュー共通のナビゲーション項目を 1 箇所で構築する (#712)。
  /// feature-gate（adapter の各 Support）とモロヘイヤ有無をここで評価する。
  /// [announcementsShownAsTab] はお知らせがタブとして可視のときに true で、
  /// その場合ドロワー / メニューからは「お知らせ」項目を出さない（重複回避）。
  /// [onActivate] はドロワー経由のとき `dismiss`（ドロワーを閉じる）を渡す。
  List<HomeNavItem> _buildNavItems(
    BuildContext context,
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
        shortcut: const SingleActivator(LogicalKeyboardKey.keyF, meta: true),
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
          onSelected: () => act(() => context.push('/lists/manage')),
        ),
      if (adapter is ChannelSupport)
        HomeNavItem(
          title: 'チャンネル',
          icon: Icons.forum,
          onSelected: () => act(() => _showChannelList(context, ref)),
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
          onSelected: () => act(() => _showClipList(context, ref)),
        ),
      if (adapter is AntennaSupport)
        HomeNavItem(
          title: 'アンテナ',
          icon: Icons.settings_input_antenna,
          onSelected: () => act(() => _showAntennaList(context, ref)),
        ),
      if (adapter is FlashSupport)
        HomeNavItem(
          title: 'Play',
          icon: Icons.play_circle_outline,
          onSelected: () => act(() => _showFlashList(context, ref)),
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
          onSelected: () => act(() => _showFavoriteTags(context, ref)),
        ),
        HomeNavItem(
          title: 'リンク',
          icon: Icons.link,
          onSelected: () => act(() => _showServerLinks(context, ref)),
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
  Future<void> _confirmLogout(BuildContext context, Account current) async {
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

  /// macOS グローバルメニュー (#712)。ドロワーと同じ [_buildNavItems] を単一
  /// ソースに「移動」「アカウント」メニューを構成し、標準の App / 編集 / 表示 /
  /// ウインドウを再構築する。
  ///
  /// 注意: [PlatformMenuBar] は macOS の native NSMenu（既定の MainMenu.xib）を
  /// 丸ごと置き換えるため、About / 終了 / Services 等は [PlatformProvidedMenuItem]
  /// で、Edit（コピー/ペースト等）は provided 型が無いので現在フォーカス中の
  /// `EditableText` へ text-editing intent を dispatch して再現する。キーボード
  /// ショートカット自体は Flutter 側で従来どおり機能するが、メニュー項目として
  /// 温存するために明示的に並べる（issue の「標準 Edit / Window / Help は温存」）。
  Widget _buildMacMenuBar(
    BuildContext context,
    Widget child,
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
    final navItems = _buildNavItems(
      context,
      current,
      accountState,
      unreadAnnouncements,
      announcementsShownAsTab,
    );
    final otherAccounts = accountState.accounts
        .where((a) => a.key != current?.key)
        .toList();

    // 編集アクションは現在フォーカス中のフィールドへ intent を送る。フォーカスが
    // テキスト以外なら no-op（intent を処理する Action が無い）。
    void editAction(Intent intent) {
      final focusCtx = FocusManager.instance.primaryFocus?.context;
      if (focusCtx != null) Actions.maybeInvoke(focusCtx, intent);
    }

    return PlatformMenuBar(
      menus: [
        // 先頭メニューは macOS ではアプリ名（capsicum）で表示される。
        PlatformMenu(
          label: 'capsicum',
          menus: [
            PlatformMenuItem(
              label: 'capsicum について',
              onSelected: () => showAboutCapsicum(context),
            ),
            PlatformMenuItem(
              label: '設定…',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.comma,
                meta: true,
              ),
              onSelected: () => context.push('/settings'),
            ),
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.servicesSubmenu,
                ),
              ],
            ),
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.hide,
                ),
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.hideOtherApplications,
                ),
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.showAllApplications,
                ),
              ],
            ),
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.quit,
                ),
              ],
            ),
          ],
        ),
        PlatformMenu(
          label: '編集',
          menus: [
            PlatformMenuItem(
              label: '取り消す',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyZ,
                meta: true,
              ),
              onSelected: () => editAction(
                const UndoTextIntent(SelectionChangedCause.keyboard),
              ),
            ),
            PlatformMenuItem(
              label: 'やり直す',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyZ,
                meta: true,
                shift: true,
              ),
              onSelected: () => editAction(
                const RedoTextIntent(SelectionChangedCause.keyboard),
              ),
            ),
            PlatformMenuItem(
              label: 'カット',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyX,
                meta: true,
              ),
              onSelected: () => editAction(
                const CopySelectionTextIntent.cut(
                  SelectionChangedCause.keyboard,
                ),
              ),
            ),
            PlatformMenuItem(
              label: 'コピー',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyC,
                meta: true,
              ),
              onSelected: () => editAction(CopySelectionTextIntent.copy),
            ),
            PlatformMenuItem(
              label: 'ペースト',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyV,
                meta: true,
              ),
              onSelected: () => editAction(
                const PasteTextIntent(SelectionChangedCause.keyboard),
              ),
            ),
            PlatformMenuItem(
              label: 'すべて選択',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyA,
                meta: true,
              ),
              onSelected: () => editAction(
                const SelectAllTextIntent(SelectionChangedCause.keyboard),
              ),
            ),
          ],
        ),
        // ドロワーと同じナビゲーション項目（単一ソース）。
        PlatformMenu(
          label: '移動',
          menus: [
            for (final item in navItems)
              PlatformMenuItem(
                label: item.title,
                shortcut: item.shortcut,
                onSelected: item.onSelected,
              ),
          ],
        ),
        if (accountState.accounts.isNotEmpty)
          PlatformMenu(
            label: 'アカウント',
            menus: [
              if (current != null)
                PlatformMenuItemGroup(
                  members: [
                    PlatformMenuItem(
                      label: 'プロフィール',
                      onSelected: () =>
                          context.push('/profile', extra: current.user),
                    ),
                  ],
                ),
              if (otherAccounts.isNotEmpty)
                PlatformMenuItemGroup(
                  members: [
                    for (final a in otherAccounts)
                      PlatformMenuItem(
                        label: '@${a.user.username}@${a.key.host}',
                        onSelected: () => ref
                            .read(accountManagerProvider.notifier)
                            .switchAccount(a),
                      ),
                  ],
                ),
              PlatformMenuItemGroup(
                members: [
                  PlatformMenuItem(
                    label: 'アカウントを追加',
                    onSelected: () => context.push('/server'),
                  ),
                  if (current != null)
                    PlatformMenuItem(
                      label: 'ログアウト',
                      onSelected: () => _confirmLogout(context, current),
                    ),
                ],
              ),
            ],
          ),
        const PlatformMenu(
          label: '表示',
          menus: [
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.toggleFullScreen,
            ),
          ],
        ),
        const PlatformMenu(
          label: 'ウインドウ',
          menus: [
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.minimizeWindow,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.zoomWindow,
            ),
          ],
        ),
      ],
      child: child,
    );
  }

  Widget _buildDrawer(
    BuildContext context,
    WidgetRef ref,
    Account? current,
    AccountManagerState accountState,
    int unreadAnnouncements, {
    bool wideLayout = false,
  }) {
    final otherAccounts = accountState.accounts
        .where((a) => a.key != current?.key)
        .toList();

    // Drawer 内の各 ListTile から `Scaffold.of(context).closeDrawer()` を
    // 呼ぶ際、`context` は _buildDrawer が受け取る HomeScreen レベルの
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
          final navItems = _buildNavItems(
            context,
            current,
            accountState,
            unreadAnnouncements,
            announcementsShownAsTab,
            onActivate: dismiss,
          );
          final list = ListView(
            padding: EdgeInsets.zero,
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
                                context.push('/profile', extra: current.user);
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
                                context.push('/profile', extra: current.user);
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
                                child: _buildServerBadge(
                                  context,
                                  ref,
                                  current.key.host,
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
              if (accountState.offlineAccounts.isNotEmpty)
                ...accountState.offlineAccounts.map((offline) {
                  final disabledColor = Theme.of(context).disabledColor;
                  return ListTile(
                    leading: Icon(Icons.person_off_outlined, color: disabledColor),
                    title: Text(
                      offline.handle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: disabledColor),
                    ),
                    subtitle: Text(
                      offline.retrying ? '接続できません（再試行中…）' : '接続できません',
                      style: TextStyle(color: disabledColor),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
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
                        IconButton(
                          icon: Icon(Icons.delete_outline, color: disabledColor),
                          tooltip: 'このアカウントを削除',
                          onPressed: () =>
                              confirmRemoveOfflineAccount(context, ref, offline),
                        ),
                      ],
                    ),
                    onTap: () {
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
                  _confirmLogout(context, current);
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
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outline,
                                  ),
                            ),
                          ),
                        Text(
                          'capsicum v${info.version} (${info.buildNumber})',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
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

  Future<void> _showFavoriteTags(BuildContext context, WidgetRef ref) async {
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

  Future<void> _showServerLinks(BuildContext context, WidgetRef ref) async {
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
              child: Text(
                'リンク',
                style: Theme.of(context).textTheme.titleMedium,
              ),
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

  Future<void> _showFlashList(BuildContext context, WidgetRef ref) async {
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

    final account = ref.read(accountManagerProvider).current;
    final host = account?.key.host;

    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Play',
                style: Theme.of(context).textTheme.titleMedium,
              ),
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
                  Navigator.pop(context);
                  if (host != null) {
                    launchUrlSafely(
                      Uri.parse('https://$host/play/${flash.id}'),
                      mode: LaunchMode.inAppBrowserView,
                    );
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showClipList(BuildContext context, WidgetRef ref) async {
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
              child: Text(
                'クリップ',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final clip in clips)
              ListTile(
                leading: const Icon(Icons.content_paste, size: 20),
                title: Text(clip.name),
                subtitle:
                    clip.description != null && clip.description!.isNotEmpty
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

  Future<void> _showAntennaList(BuildContext context, WidgetRef ref) async {
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
              child: Text(
                'アンテナ',
                style: Theme.of(context).textTheme.titleMedium,
              ),
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

  Future<void> _showChannelList(BuildContext context, WidgetRef ref) async {
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

  Widget _buildServerBadge(BuildContext context, WidgetRef ref, String host) {
    final themeColors = ref.watch(hostThemeColorProvider);
    return ServerBadge.fromHost(host, themeColors: themeColors);
  }
}

/// 本線タイムラインのライブ更新（streaming）接続状態を常時表示する小さな
/// ドット (#714)。`timelineProvider` の [StreamConnectionState] を反映する。
/// 枯渇可視化 (#588) も exhausted 状態として内包する。
/// TL provider の現在値が「別文脈で取得した前のキャッシュ」か判定する (#758)。
///
/// 期待 contextKey（現在のアカウント＋タブ/タグ/リスト）と state が持つ
/// contextKey が食い違えば stale。account→adapter→timeline の dirty 伝播が
/// 遅れて `isLoading=false` のまま前文脈の値が残るケースを拾う。HomeScreen 本体
/// の TL 差し替え（[_HomeScreenState.build]）と接続インジケータの色
/// （[_StreamStatusIndicator]）が同じ判定を共有し、片方だけ条件が変わって
/// silently drift するのを防ぐため 1 箇所に集約する (#764)。
bool _timelineIsStale(AsyncValue<dynamic> async, String? expectedContextKey) =>
    expectedContextKey != null &&
    async.valueOrNull?.contextKey != expectedContextKey;

class _StreamStatusIndicator extends ConsumerStatefulWidget {
  const _StreamStatusIndicator();

  @override
  ConsumerState<_StreamStatusIndicator> createState() =>
      _StreamStatusIndicatorState();
}

class _StreamStatusIndicatorState
    extends ConsumerState<_StreamStatusIndicator> {
  // 速い再接続は色のちらつきだけだと目視できないため、切断検知 (reconnectCount
  // 増加) で一定時間 橙をラッチして必ず見えるようにする (#782)。
  Timer? _flashTimer;
  bool _flashing = false;
  int? _seenReconnectCount;

  @override
  void dispose() {
    _flashTimer?.cancel();
    super.dispose();
  }

  void _onReconnectCount(int count) {
    final prev = _seenReconnectCount;
    _seenReconnectCount = count;
    if (prev != null && count > prev && mounted) {
      _flashTimer?.cancel();
      setState(() => _flashing = true);
      _flashTimer = Timer(const Duration(milliseconds: 1200), () {
        if (mounted) setState(() => _flashing = false);
      });
    }
  }

  static String _fmtTime(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(timelineProvider);
    // 切断検知 (reconnectCount 増加) を拾って flash を発火する (#782)。
    ref.listen(timelineProvider, (prev, next) {
      _onReconnectCount(next.valueOrNull?.reconnectCount ?? 0);
    });
    // リロード中（アカウント/文脈切替・起動時の current 着地・pull-to-refresh）は
    // 直前 state の接続状態が valueOrNull に残るため、そのまま読むと「前のアカウント
    // の緑」を新しい文脈のロード完了まで見せてしまう。低速回線ではこの窓が数秒に
    // 伸び、サーバーは新 TL を返しているのに「緑なのに中身が来ない/古い」体感に
    // なる。build() 実行中（isLoading）に加え、state.contextKey が現在の期待キーと
    // 食い違う（＝前文脈のキャッシュ。dirty 伝播が遅れて isLoading=false のまま残る
    // ケース）間も connecting を表示し、緑は「この文脈の TL がロード済み＋live」
    // だけを意味するようにする (#758)。
    final expectedContextKey = timelineContextKey(
      ref.watch(currentAccountProvider)?.key,
      'tl:${ref.watch(selectedTimelineTypeProvider).name}',
    );
    final stale = _timelineIsStale(async, expectedContextKey);
    // 前文脈のキャッシュや build 中は再接続カウント等を出さない（現在の文脈の
    // 値だけを正直に出すため）。
    final st = (async.isLoading || stale) ? null : async.valueOrNull;
    final conn = st?.streamConnectionState ?? StreamConnectionState.connecting;
    final (Color baseColor, String label) = switch (conn) {
      StreamConnectionState.live => (Colors.green, 'ライブ更新中'),
      StreamConnectionState.connecting => (Colors.amber, '接続中…'),
      StreamConnectionState.disconnected => (Colors.orange, '切断 — 再接続中'),
      // #784 で give-up しなくなったため「停止」ではなく「不安定・再試行中」。
      StreamConnectionState.exhausted => (
        Theme.of(context).colorScheme.error,
        '接続が不安定 — 再試行中',
      ),
    };
    // 速い再接続でも見えるよう、flash 中は live でも切断色を見せる (#782)。
    final color = (_flashing && conn == StreamConnectionState.live)
        ? Colors.orange
        : baseColor;

    // 再接続の詳細 (回数バッジ + 直近切断時刻) は既定で隠し、診断したい人だけ
    // 設定で ON にする (#786)。切断・再接続は正常挙動で、回数表示は一般ユーザーを
    // 不安にさせる逆効果のため。接続状態ラベルと flash は設定に関わらず常時出す。
    final showDetail = ref.watch(showStreamReconnectDetailProvider);
    final count = st?.reconnectCount ?? 0;
    final lastAt = st?.lastDisconnectedAt;
    final tooltip = StringBuffer('ライブ更新: $label');
    if (showDetail && count > 0) {
      tooltip.write('\n再接続 $count 回');
      if (lastAt != null) tooltip.write('・直近切断 ${_fmtTime(lastAt)}');
    }

    return Tooltip(
      message: tooltip.toString(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 10, color: color),
            // 再接続回数を小さく併記し、「ちょくちょく切れている」を回数で正直に
            // 見せる (#782)。既定では隠し、詳細表示 ON かつ 0 でないときだけ出す
            // (#786)。
            if (showDetail && count > 0) ...[
              const SizedBox(width: 3),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LivecureFilterButton extends StatelessWidget {
  final WidgetRef ref;

  const _LivecureFilterButton({required this.ref});

  @override
  Widget build(BuildContext context) {
    final hide = ref.watch(hideLivecureProvider);
    return IconButton(
      icon: Icon(
        hide ? Icons.mic_off : Icons.mic,
        color: hide ? Theme.of(context).colorScheme.error : null,
      ),
      tooltip: hide ? '#実況 非表示中' : '#実況 表示中',
      onPressed: () => ref.read(hideLivecureProvider.notifier).toggle(),
    );
  }
}

/// AppBar 右上の通知ベル。
///
/// - 単一アカウント: タップで現在アカウントの通知画面（/notifications）
/// - 複数アカウント: タップでまとめ画面（/notifications/all）— #345 で変更
/// - 長押しでポップアップメニューから明示選択も可能
class _NotificationBellButton extends StatelessWidget {
  final bool hasMultipleAccounts;

  const _NotificationBellButton({required this.hasMultipleAccounts});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: hasMultipleAccounts ? () => _showMenu(context) : null,
      child: IconButton(
        icon: const Icon(Icons.notifications_outlined),
        // 複数アカウント時は長押しメニューを自前で出すため IconButton の
        // tooltip は付けない。built-in tooltip が long-press gesture を
        // 横取りして、外側の GestureDetector.onLongPress が発火しない。
        tooltip: hasMultipleAccounts ? null : '通知',
        onPressed: () => context.push(
          hasMultipleAccounts ? '/notifications/all' : '/notifications',
        ),
      ),
    );
  }

  Future<void> _showMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    // PopupMenuItem + ListTile は default height 制約（48dp）と ListTile の
    // 推奨高（56dp+）がぶつかって 2 つ目以降が見切れる事象があったため、
    // Row ベースのコンパクトなレイアウトに変更している。
    final selection = await showMenu<String>(
      context: context,
      position: position,
      items: const [
        PopupMenuItem(
          value: '/notifications/all',
          child: Row(
            children: [
              Icon(Icons.notifications_active_outlined, size: 20),
              SizedBox(width: 12),
              Text('すべての通知'),
            ],
          ),
        ),
        PopupMenuItem(
          value: '/notifications',
          child: Row(
            children: [
              Icon(Icons.notifications_outlined, size: 20),
              SizedBox(width: 12),
              Text('このアカウントの通知'),
            ],
          ),
        ),
      ],
    );
    if (selection != null && context.mounted) context.push(selection);
  }
}

/// オンラインで使えるアカウントが無く、到達不能でオフライン保持中のアカウント
/// だけがある状態の代替ホーム (#792)。ログイン画面へ戻さずに「接続できません
/// ／再試行中」を表示し、サーバー復帰で自動的に通常のタイムラインへ戻る
/// （復元成功でオフライン → オンライン昇格し、`account != null` になった時点で
/// [HomeScreen.build] が通常経路を返す）。
class _OfflineHomeScaffold extends ConsumerWidget {
  const _OfflineHomeScaffold();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(offlineAccountsProvider);
    final anyRetrying = offline.any((o) => o.retrying);

    return Scaffold(
      appBar: AppBar(
        title: const Text('接続できません'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Icon(
                Icons.cloud_off,
                size: 64,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(
                anyRetrying ? 'サーバーに接続中…' : 'サーバーに接続できません',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'ログイン中のサーバーが停止しているか、再構築中の可能性があります。'
                'アカウントは保持しているので、サーバーが復帰すると自動的に'
                'タイムラインへ戻ります。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              for (final o in offline)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.person_off_outlined),
                    title: Text(
                      o.handle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(o.retrying ? '再試行中…' : '接続できません'),
                    trailing: IconButton(
                      icon: const Icon(Icons.logout),
                      tooltip: 'このアカウントを削除',
                      onPressed: () =>
                        confirmRemoveOfflineAccount(context, ref, o),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => ref
                    .read(accountManagerProvider.notifier)
                    .retryOfflineRestores(),
                icon: const Icon(Icons.refresh),
                label: const Text('今すぐ再試行'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => context.push('/server'),
                icon: const Icon(Icons.person_add),
                label: const Text('別のアカウントでログイン'),
              ),
            ],
          ),
        ),
      ),
    );
  }

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

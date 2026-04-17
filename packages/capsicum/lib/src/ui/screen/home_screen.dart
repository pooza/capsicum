import 'dart:async';
import 'dart:io';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../constants.dart';
import '../../model/account.dart';
import '../../url_helper.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/announcement_provider.dart';
import '../../provider/hashtag_provider.dart';
import '../../provider/list_provider.dart';
import '../../provider/marker_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../util/post_scope_display.dart';
import '../../provider/timeline_provider.dart';
import '../../provider/unread_badge_provider.dart';
import '../widget/emoji_text.dart';
import '../widget/server_badge.dart';
import '../widget/user_avatar.dart';
import '../widget/post_tile.dart';
import '../widget/simple_post_bar.dart';
import '../widget/tab_management_sheet.dart';

/// Currently selected list ID (null = normal timeline mode).
final selectedListProvider = StateProvider<PostList?>((ref) => null);

/// Currently selected pinned hashtag (null = not in hashtag tab mode).
final selectedHashtagProvider = StateProvider<String?>((ref) => null);

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
    if (timeline != null && !timeline.isLoadingMore) {
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

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null || adapter is! MarkerSupport) return;

    try {
      final markers = await (adapter as MarkerSupport).getMarkers();
      if (markers.home == null) return;

      final markerId = markers.home!.lastReadId;
      final index = posts.indexWhere((p) => p.id == markerId);
      if (index > 0 && mounted && _itemScrollController.isAttached) {
        _itemScrollController.jumpTo(index: index);
      }
    } catch (_) {
      // Marker fetch failed — silently ignore.
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(currentAccountProvider);
    final accountState = ref.watch(accountManagerProvider);
    final selectedType = ref.watch(selectedTimelineTypeProvider);
    final selectedList = ref.watch(selectedListProvider);
    final selectedHashtag = ref.watch(selectedHashtagProvider);
    final unreadAnnouncements = ref.watch(unreadAnnouncementCountProvider);

    // Restore last selected tab once the saved value arrives from disk.
    // Reset when the active account changes so each account gets its own tab.
    if (account != null) {
      final storageKey = account.key.toStorageKey();
      if (_lastTabRestoredForAccount != storageKey) {
        _lastTabRestored = false;
        _lastTabRestoredForAccount = storageKey;
        _pendingListRestore = null;
        // Clear previous account's selection to avoid referencing
        // lists/hashtags that don't exist on the new account.
        ref.read(selectedListProvider.notifier).state = null;
        ref.read(selectedHashtagProvider.notifier).state = null;
        ref.read(selectedTimelineTypeProvider.notifier).state =
            TimelineType.home;
      }
      if (!_lastTabRestored) {
        ref.listen(lastTabProvider(storageKey), (prev, next) {
          if (!_lastTabRestored && next != null) {
            _lastTabRestored = true;
            _applyLastTab(next);
          }
        });
        // Also check synchronously in case the value was already loaded.
        final saved = ref.read(lastTabProvider(storageKey));
        if (!_lastTabRestored && saved != null) {
          _lastTabRestored = true;
          _applyLastTab(saved);
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
          ref.read(selectedListProvider.notifier).state = list;
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

    return Scaffold(
      appBar: AppBar(
        leading: Builder(
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
          _LivecureFilterButton(ref: ref),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            onPressed: () => context.push('/notifications'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: _buildTimelineTabs(
            context,
            selectedType,
            selectedList,
            selectedHashtag,
          ),
        ),
      ),
      drawer: _buildDrawer(
        context,
        ref,
        account,
        accountState,
        unreadAnnouncements,
      ),
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
      body: _buildBody(selectedList, selectedType, selectedHashtag, timeline),
    );
  }

  Widget _buildBody(
    PostList? selectedList,
    TimelineType selectedType,
    String? selectedHashtag,
    AsyncValue<dynamic> timeline,
  ) {
    final storageKey = ref.watch(currentAccountProvider)?.key.toStorageKey();
    final bgPath = storageKey != null
        ? ref.watch(backgroundImageProvider(storageKey))
        : null;
    final bgOpacity = storageKey != null
        ? ref.watch(backgroundOpacityProvider(storageKey))
        : defaultBackgroundOpacity;

    Widget body = Column(
      children: [
        Expanded(
          child: GestureDetector(
            onHorizontalDragEnd: selectedList == null
                ? (details) => _onSwipe(details, selectedType)
                : null,
            child: timeline.when(
              data: (tlState) {
                // Restore marker position on first load (home timeline only).
                if (selectedList == null &&
                    selectedType == TimelineType.home &&
                    tlState.posts.isNotEmpty) {
                  _restoreMarker(tlState.posts);
                }
                return RefreshIndicator(
                  onRefresh: () {
                    _markerRestored = false;
                    if (selectedHashtag != null) {
                      return ref.refresh(
                        hashtagTimelineProvider(selectedHashtag).future,
                      );
                    }
                    if (selectedList != null) {
                      return ref.refresh(
                        listTimelineProvider(selectedList.id).future,
                      );
                    }
                    return ref.refresh(timelineProvider.future);
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

  void _onSwipe(DragEndDetails details, TimelineType current) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 300) return;

    final adapter = ref.read(currentAdapterProvider);
    final supported =
        adapter?.capabilities.supportedTimelines ??
        {TimelineType.home, TimelineType.local, TimelineType.federated};
    final account = ref.read(currentAccountProvider);
    final storageKey = account?.key.toStorageKey();
    final order = account != null
        ? ref.read(tabOrderProvider(storageKey!))
        : defaultTabOrder;
    final hiddenTypes = storageKey != null
        ? ref.read(hiddenTimelineTypesProvider(storageKey))
        : <TimelineType>{};
    final tabs = order
        .where((t) => supported.contains(t) && !hiddenTypes.contains(t))
        .toList();
    final index = tabs.indexOf(current);
    if (index < 0) return;

    final next = velocity < 0 ? index + 1 : index - 1;
    if (next < 0 || next >= tabs.length) return;

    ref.read(selectedTimelineTypeProvider.notifier).state = tabs[next];
    _saveLastTab();
  }

  /// Persist the currently selected tab to SharedPreferences.
  void _saveLastTab() {
    final account = ref.read(currentAccountProvider);
    if (account == null) return;
    final storageKey = account.key.toStorageKey();

    final hashtag = ref.read(selectedHashtagProvider);
    final list = ref.read(selectedListProvider);
    final String value;
    if (hashtag != null) {
      value = 'hashtag:$hashtag';
    } else if (list != null) {
      value = 'list:${list.id}';
    } else {
      value = 'timeline:${ref.read(selectedTimelineTypeProvider).name}';
    }
    ref.read(lastTabProvider(storageKey).notifier).save(value);
  }

  /// Apply a saved tab value to the current selection providers.
  void _applyLastTab(String saved) {
    final parts = saved.split(':');
    if (parts.length < 2) return;
    final kind = parts[0];
    final value = parts.sublist(1).join(':');

    switch (kind) {
      case 'timeline':
        final type = TimelineType.values
            .where((t) => t.name == value)
            .firstOrNull;
        if (type != null) {
          final adapter = ref.read(currentAdapterProvider);
          final supported =
              adapter?.capabilities.supportedTimelines ??
              {TimelineType.home, TimelineType.local, TimelineType.federated};
          if (supported.contains(type)) {
            ref.read(selectedTimelineTypeProvider.notifier).state = type;
          }
        }
      case 'list':
        final lists = ref.read(listsProvider).valueOrNull ?? [];
        final list = lists.where((l) => l.id == value).firstOrNull;
        if (list != null) {
          ref.read(selectedListProvider.notifier).state = list;
        } else {
          // Lists may not be loaded yet — defer until they arrive.
          _pendingListRestore = value;
        }
      case 'hashtag':
        final account = ref.read(currentAccountProvider);
        if (account != null) {
          final pinned = ref.read(
            pinnedHashtagsProvider(account.key.toStorageKey()),
          );
          if (pinned.contains(value)) {
            ref.read(selectedHashtagProvider.notifier).state = value;
          }
        }
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

  Widget _buildTimelineTabs(
    BuildContext context,
    TimelineType selected,
    PostList? selectedList,
    String? selectedHashtag,
  ) {
    final adapter = ref.watch(currentAdapterProvider);
    final supported =
        adapter?.capabilities.supportedTimelines ??
        {TimelineType.home, TimelineType.local, TimelineType.federated};
    final isMastodon = !supported.contains(TimelineType.social);

    // Use user-customized tab order if available.
    final account = ref.watch(currentAccountProvider);
    final storageKey = account?.key.toStorageKey();
    final order = account != null
        ? ref.watch(tabOrderProvider(storageKey!))
        : defaultTabOrder;
    final hiddenTypes = storageKey != null
        ? ref.watch(hiddenTimelineTypesProvider(storageKey))
        : <TimelineType>{};
    final tabs = order
        .where((t) => supported.contains(t) && !hiddenTypes.contains(t))
        .toList();

    // Fetch lists (filtered and ordered).
    final listsAsync = ref.watch(listsProvider);
    final allLists = listsAsync.valueOrNull ?? [];
    final hiddenIds = storageKey != null
        ? ref.watch(hiddenListIdsProvider(storageKey))
        : <String>{};
    final listOrder = storageKey != null
        ? ref.watch(listOrderProvider(storageKey))
        : <String>[];
    final visibleLists = allLists
        .where((l) => !hiddenIds.contains(l.id))
        .toList();
    if (listOrder.isNotEmpty) {
      visibleLists.sort((a, b) {
        final ai = listOrder.indexOf(a.id);
        final bi = listOrder.indexOf(b.id);
        if (ai == -1 && bi == -1) return 0;
        if (ai == -1) return 1;
        if (bi == -1) return -1;
        return ai.compareTo(bi);
      });
    }

    // Pinned hashtags.
    final pinnedHashtags = storageKey != null
        ? ref.watch(pinnedHashtagsProvider(storageKey))
        : <String>[];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          // Timeline type tabs.
          ...tabs.map((type) {
            var label =
                (isMastodon ? _mastodonLabelOverrides[type] : null) ??
                _timelineLabels[type] ??
                (type == TimelineType.directMessages
                    ? postScopeLabel(PostScope.direct, adapter)
                    : type.name);
            if (type == TimelineType.local) {
              label = ref.watch(localTimelineNameProvider);
            }
            final isSelected =
                selectedList == null &&
                selectedHashtag == null &&
                type == selected;
            return _tabChip(context, label, isSelected, () {
              ref.read(selectedListProvider.notifier).state = null;
              ref.read(selectedHashtagProvider.notifier).state = null;
              ref.read(selectedTimelineTypeProvider.notifier).state = type;
              _saveLastTab();
            });
          }),
          // List tabs.
          ...visibleLists.map((list) {
            final isSelected =
                selectedHashtag == null && selectedList?.id == list.id;
            return _tabChip(context, list.title, isSelected, () {
              ref.read(selectedHashtagProvider.notifier).state = null;
              ref.read(selectedListProvider.notifier).state = list;
              _saveLastTab();
            });
          }),
          // Pinned hashtag tabs.
          ...pinnedHashtags.map((tag) {
            final isSelected = selectedHashtag == tag;
            return _tabChip(context, hashtagSpecLabel(tag), isSelected, () {
              ref.read(selectedListProvider.notifier).state = null;
              ref.read(selectedHashtagProvider.notifier).state = tag;
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
  }

  void _showTabManagement(BuildContext context) {
    final account = ref.read(currentAccountProvider);
    if (account == null) return;
    final storageKey = account.key.toStorageKey();
    final lists = ref.read(listsProvider).valueOrNull ?? [];
    final adapter = ref.read(currentAdapterProvider);
    final supported =
        adapter?.capabilities.supportedTimelines ??
        {TimelineType.home, TimelineType.local, TimelineType.federated};
    final isMastodon = !supported.contains(TimelineType.social);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => TabManagementSheet(
        storageKey: storageKey,
        allLists: lists,
        supportedTimelines: supported,
        isMastodon: isMastodon,
      ),
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

  Widget _buildDrawer(
    BuildContext context,
    WidgetRef ref,
    Account? current,
    AccountManagerState accountState,
    int unreadAnnouncements,
  ) {
    final otherAccounts = accountState.accounts
        .where((a) => a.key != current?.key)
        .toList();

    return Drawer(
      child: ListView(
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
                            Navigator.of(context).pop();
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
                            Navigator.of(context).pop();
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
                          style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '@${current?.user.username ?? ""}@${current?.key.host ?? ""}',
                          style: const TextStyle(color: Colors.black),
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                  Navigator.of(context).pop();
                },
              );
            }),
          ],
          ListTile(
            leading: const Icon(Icons.person_add),
            title: const Text('アカウントを追加'),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/server');
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.search),
            title: const Text('検索'),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/search');
            },
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('通知'),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/notifications');
            },
          ),
          if (accountState.accounts.length > 1)
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('すべての通知'),
              onTap: () {
                Navigator.of(context).pop();
                context.push('/notifications/all');
              },
            ),
          ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: Text(
              ref.read(currentAdapterProvider) is ReactionSupport
                  ? 'お気に入り'
                  : 'ブックマーク',
            ),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/bookmarks');
            },
          ),
          ListTile(
            leading: const Icon(Icons.campaign_outlined),
            title: const Text('お知らせ'),
            trailing: unreadAnnouncements > 0
                ? Badge(label: Text('$unreadAnnouncements'))
                : null,
            onTap: () {
              Navigator.of(context).pop();
              context.push('/announcements');
            },
          ),
          if (ref.read(currentAdapterProvider) is ListSupport)
            ListTile(
              leading: const Icon(Icons.list),
              title: const Text('リスト'),
              onTap: () {
                Navigator.of(context).pop();
                context.push('/lists/manage');
              },
            ),
          if (ref.read(currentAdapterProvider) is ChannelSupport)
            ListTile(
              leading: const Icon(Icons.forum),
              title: const Text('チャンネル'),
              onTap: () {
                Navigator.of(context).pop();
                _showChannelList(context, ref);
              },
            ),
          if (ref.read(currentAdapterProvider) is DriveSupport)
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('ドライブ'),
              onTap: () {
                Navigator.of(context).pop();
                context.push('/drive');
              },
            ),
          if (ref.read(currentAdapterProvider) is ClipSupport)
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('クリップ'),
              onTap: () {
                Navigator.of(context).pop();
                _showClipList(context, ref);
              },
            ),
          if (ref.read(currentAdapterProvider) is AntennaSupport)
            ListTile(
              leading: const Icon(Icons.settings_input_antenna),
              title: const Text('アンテナ'),
              onTap: () {
                Navigator.of(context).pop();
                _showAntennaList(context, ref);
              },
            ),
          if (ref.read(currentAdapterProvider) is FlashSupport)
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: const Text('Play'),
              onTap: () {
                Navigator.of(context).pop();
                _showFlashList(context, ref);
              },
            ),
          if (ref.read(currentAdapterProvider) is GallerySupport)
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('ギャラリー'),
              onTap: () {
                Navigator.of(context).pop();
                context.push('/gallery');
              },
            ),
          if (ref.read(currentMulukhiyaProvider) != null) ...[
            ListTile(
              leading: const Icon(Icons.tag),
              title: const Text('プロフィールタグ'),
              onTap: () {
                Navigator.of(context).pop();
                _showFavoriteTags(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('リンク'),
              onTap: () {
                Navigator.of(context).pop();
                _showServerLinks(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('メディアカタログ'),
              onTap: () {
                Navigator.of(context).pop();
                context.push('/media-catalog');
              },
            ),
          ],
          if (ref.read(currentAdapterProvider) is ScheduleSupport)
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('予約投稿'),
              onTap: () {
                Navigator.of(context).pop();
                context.push('/scheduled');
              },
            ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('サーバー情報'),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/server-info');
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('設定'),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/settings');
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('ログアウト'),
            onTap: () async {
              Navigator.of(context).pop();
              if (current == null) return;

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
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('capsicum について'),
            onTap: () async {
              Navigator.of(context).pop();
              final info = await PackageInfo.fromPlatform();
              if (!context.mounted) return;
              showAboutDialog(
                context: context,
                applicationName: AppConstants.appName,
                applicationVersion: 'v${info.version} (${info.buildNumber})',
                applicationIcon: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset(
                    'assets/images/logo.png',
                    width: 48,
                    height: 48,
                  ),
                ),
                applicationLegalese: 'Mastodon / Misskey クライアント',
                children: [
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () => launchUrlSafely(AppConstants.websiteUrl),
                    child: Text(
                      AppConstants.websiteUrl.toString(),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () => launchUrlSafely(AppConstants.communityUrl),
                    child: Text(
                      'コミュニティ（PieFed）',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () => launchUrlSafely(AppConstants.contactUrl),
                    child: Text(
                      'お問い合わせ',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              );
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
                    Navigator.of(context).pop();
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
                    Navigator.of(context).pop();
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
                  Navigator.of(context).pop();
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
                  Navigator.of(context).pop();
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
                  Navigator.of(context).pop();
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
                  Navigator.of(context).pop();
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

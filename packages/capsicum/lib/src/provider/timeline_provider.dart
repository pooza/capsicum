import 'dart:async';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../service/exception_scrub.dart';
import 'account_manager_provider.dart';
import 'preferences_provider.dart';

/// Currently selected tab (unified across all tab types).
final selectedTabProvider = StateProvider<TabType>(
  (ref) => const TimelineTab(TimelineType.home),
);

/// Tab that HomeScreen should focus on its next build.
///
/// Set by external entry points (notification taps, share intents) that want
/// to land the user on a specific tab. HomeScreen consumes and clears the
/// value after applying it, and in doing so short-circuits the last-tab
/// restore so the saved tab does not overwrite the requested focus.
final pendingInitialTabProvider = StateProvider<TabType?>((ref) => null);

/// Currently selected timeline type, derived from [selectedTabProvider].
///
/// Returns [TimelineType.home] when the active tab is not a timeline.
/// Kept for backward-compatibility with [TimelineNotifier] and other
/// providers that watch only the timeline type.
final selectedTimelineTypeProvider = Provider<TimelineType>((ref) {
  final tab = ref.watch(selectedTabProvider);
  return tab is TimelineTab ? tab.type : TimelineType.home;
});

/// `null` 自体が「明示的にクリア」を意味する nullable フィールドを
/// `copyWith` で保持／差し替えするための sentinel (#455 / #450 と同型)。
const Object _keepLoadMoreError = Object();

/// build() / fetchUntilVisible のページ取得ループの試行ページ数上限 (#601)。
/// 実況フィルタ ON で API が満杯ページを返し続けると、可視投稿が 1 件見つかる
/// までページ取得が連発しレートリミットに達しうるため上限で打ち切る。
const int kMaxVisibilityPageFetches = 10;

/// ページ取得上限に達したことを Sentry breadcrumb に残す (#601 2 回目レビュー追従)。
/// 「全件フィルタで空一覧になる」ユーザー報告を後から切り分けるための観測ライン。
/// 同じ category を全 3 経路 (build / fetchUntilVisible / loadMore) で共有する。
void _recordPageCapHit({
  required String site,
  required int visibleCollected,
  required bool hasMore,
}) {
  Sentry.addBreadcrumb(
    Breadcrumb(
      message: 'timeline page cap hit',
      category: 'timeline.page_cap',
      level: SentryLevel.info,
      data: {
        'site': site,
        'cap': kMaxVisibilityPageFetches,
        'visibleCollected': visibleCollected,
        'hasMore': hasMore,
      },
    ),
  );
}

/// Paginated timeline state.
class TimelineState {
  final List<Post> posts;
  final bool isLoadingMore;
  final bool hasMore;

  /// Non-null when the last [loadMore] call failed.  Cleared on the next
  /// successful load so the UI can show a transient error (e.g. SnackBar).
  final Object? loadMoreError;

  /// Number of new posts queued while the user is scrolling.
  final int pendingCount;

  /// streaming の再接続上限に到達して新規投稿が来なくなった状態 (#586)。
  /// REST で取得済みの投稿はそのまま見えるが、ライブ更新は止まっている。
  /// pull-to-refresh / タブ再選択で build() が再実行されるとクリアされる。
  final bool streamReconnectExhausted;

  const TimelineState({
    this.posts = const [],
    this.isLoadingMore = false,
    this.hasMore = true,
    this.loadMoreError,
    this.pendingCount = 0,
    this.streamReconnectExhausted = false,
  });

  /// [loadMoreError] は引数省略時に現状を保持する。明示的に `null` を渡した
  /// 場合はクリア、例外を渡した場合は差し替え、という三状態を区別する
  /// (#455 / #450 と同型)。
  TimelineState copyWith({
    List<Post>? posts,
    bool? isLoadingMore,
    bool? hasMore,
    Object? loadMoreError = _keepLoadMoreError,
    int? pendingCount,
    bool? streamReconnectExhausted,
  }) => TimelineState(
    posts: posts ?? this.posts,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    hasMore: hasMore ?? this.hasMore,
    loadMoreError: identical(loadMoreError, _keepLoadMoreError)
        ? this.loadMoreError
        : loadMoreError,
    pendingCount: pendingCount ?? this.pendingCount,
    streamReconnectExhausted:
        streamReconnectExhausted ?? this.streamReconnectExhausted,
  );
}

/// Maximum number of automatic retries for [loadMore] on transient failure.
const loadMoreMaxRetries = 2;

/// Delay between [loadMore] retry attempts.
const loadMoreRetryDelay = Duration(seconds: 2);

final _livecurePattern = RegExp(r'(#実況[\s<]|#<span>実況</span>)');

/// Check whether a post contains the livecure (#実況) hashtag.
/// Bot posts are excluded — their #実況 announcements should remain visible.
bool hasLivecureTag(Post post) {
  final target = post.reblog ?? post;
  if (target.author.isBot) return false;
  final content = target.content ?? '';
  return _livecurePattern.hasMatch(content) || content.endsWith('#実況');
}

/// Fetch pages until at least one post survives client-side filtering, or the
/// source is exhausted.
///
/// Without this, a first page that is entirely #実況 (with hideLivecure on)
/// yields an empty timeline that never auto-loads the next page, because the
/// list has nothing to scroll. Shared by the list/hashtag/channel build()s so
/// they get the same behaviour TimelineNotifier.build() already has (#583; the
/// original fix for the home timeline was #230).
///
/// [fetch] takes the pagination cursor (null for the first page, otherwise the
/// last fetched post's id) and returns one raw page.
Future<TimelineState> fetchUntilVisible({
  required int pageSize,
  required bool hideLivecure,
  required Future<List<Post>> Function(String? maxId) fetch,
}) async {
  final allVisible = <Post>[];
  String? maxId;
  var hasMore = true;
  var fetches = 0;

  while (hasMore && fetches < kMaxVisibilityPageFetches) {
    fetches++;
    final posts = await fetch(maxId);
    if (posts.isEmpty) {
      hasMore = false;
      break;
    }
    maxId = posts.last.id;
    hasMore = posts.length >= pageSize;

    final visible = hideLivecure
        ? posts.where((p) => !hasLivecureTag(p)).toList()
        : posts;
    allVisible.addAll(visible);

    if (allVisible.isNotEmpty || !hasMore) break;
  }

  if (fetches >= kMaxVisibilityPageFetches && allVisible.isEmpty && hasMore) {
    _recordPageCapHit(
      site: 'fetchUntilVisible',
      visibleCollected: 0,
      hasMore: true,
    );
  }

  return TimelineState(posts: allVisible, hasMore: hasMore);
}

/// Notifier that manages paginated timeline fetching with optional streaming.
class TimelineNotifier extends AutoDisposeAsyncNotifier<TimelineState> {
  static const _pageSize = 20;
  StreamSubscription<Post>? _streamSubscription;
  final List<Post> _pendingPosts = [];
  final Map<String, bool> _isCatCache = {};
  bool _isNearTop = true;

  @override
  Future<TimelineState> build() async {
    // build() reruns when adapter / timeline type changes. Reset stream-side
    // state so queued posts from a previous timeline context cannot leak
    // into the new one via flushPending().
    _pendingPosts.clear();
    _isNearTop = true;

    final adapter = ref.watch(currentAdapterProvider);
    final type = ref.watch(selectedTimelineTypeProvider);
    if (adapter == null) return const TimelineState();

    // Initial REST fetch — retry pages until visible posts are found or the
    // timeline is exhausted (same logic as loadMore).
    final hideLivecure = ref.watch(hideLivecureProvider);
    final allVisible = <Post>[];
    String? maxId;
    bool hasMore = true;
    var fetches = 0;

    while (hasMore && fetches < kMaxVisibilityPageFetches) {
      fetches++;
      final response = await adapter.getTimeline(
        type,
        query: TimelineQuery(maxId: maxId, limit: _pageSize),
      );

      if (response.posts.isEmpty) {
        final rawLast = response.rawLastId;
        if (rawLast != null && rawLast != maxId) {
          hasMore = response.rawCount > 0;
          maxId = rawLast;
          if (hasMore) continue;
        }
        hasMore = false;
        break;
      }

      hasMore = response.rawCount > 0;
      maxId = response.posts.last.id;

      final visible = response.posts
          .where((p) => p.filterAction != FilterAction.hide)
          .where((p) => !hideLivecure || !_hasLivecureTag(p))
          .toList();
      allVisible.addAll(visible);

      if (allVisible.isNotEmpty || !hasMore) break;
    }

    if (fetches >= kMaxVisibilityPageFetches && allVisible.isEmpty && hasMore) {
      _recordPageCapHit(site: 'build', visibleCollected: 0, hasMore: true);
    }

    // Start streaming if supported.
    if (adapter is StreamSupport) {
      _startStreaming(adapter as StreamSupport, type);
    }

    ref.onDispose(() {
      _streamSubscription?.cancel();
      if (adapter is StreamSupport) {
        (adapter as StreamSupport).disposeStream();
      }
    });

    final enriched = await _enrichIsCat(allVisible);
    return TimelineState(posts: enriched, hasMore: hasMore);
  }

  // streaming 内部の parse / 接続 / listen error を観測層へ流す (#586)。
  // chat_provider (#448 / #552) と同型: breadcrumb は毎回、captureException は
  // throttle して切断中の連発 spam を防ぐ。host 分岐は入れない (全サーバー共通
  // の計装)。バケットは性質ごとに分離 (#602): connect エラー後 60s 以内に
  // listener 経路の例外 (_applyWordFilter 異常等) が出ても抑制しないように、
  // _lastListenCapture を独立に持つ。
  DateTime? _lastParseCapture;
  DateTime? _lastConnectCapture;
  DateTime? _lastListenCapture;
  static const _captureThrottle = Duration(seconds: 60);

  void _startStreaming(StreamSupport adapter, TimelineType type) {
    _streamSubscription?.cancel();
    final stream = adapter.streamTimeline(
      type,
      onParseError: (e, st) {
        Sentry.addBreadcrumb(
          Breadcrumb(
            category: 'timeline.stream.parse',
            level: SentryLevel.warning,
            // 例外型のみ。FormatException.toString() はパース対象の生データ
            // 断片（投稿本文を含みうる）を持つため breadcrumb には載せない。
            // 詳細は下の captureException(scrubException(e)) で送る。
            message: e.runtimeType.toString(),
          ),
        );
        final now = DateTime.now();
        if (_lastParseCapture != null &&
            now.difference(_lastParseCapture!) < _captureThrottle) {
          return;
        }
        _lastParseCapture = now;
        Sentry.captureException(
          scrubException(e),
          stackTrace: st,
          withScope: (scope) {
            scope.setTag('timeline.stream.parse', 'failed');
            scope.fingerprint = [
              'timeline.stream.parse',
              e.runtimeType.toString(),
            ];
          },
        );
      },
      onStreamError: (e, st) {
        Sentry.addBreadcrumb(
          Breadcrumb(
            category: 'timeline.stream.connect',
            level: SentryLevel.warning,
            message: e.runtimeType.toString(),
          ),
        );
        final now = DateTime.now();
        if (_lastConnectCapture != null &&
            now.difference(_lastConnectCapture!) < _captureThrottle) {
          return;
        }
        _lastConnectCapture = now;
        Sentry.captureException(
          scrubException(e),
          stackTrace: st,
          withScope: (scope) {
            scope.setTag('timeline.stream.connect', 'failed');
            scope.fingerprint = [
              'timeline.stream.connect',
              e.runtimeType.toString(),
            ];
          },
        );
      },
      onReconnectExhausted: () {
        Sentry.captureMessage(
          'timeline.stream.reconnect_exhausted',
          level: SentryLevel.warning,
          withScope: (scope) {
            scope.setTag('timeline.stream', 'reconnect_exhausted');
            scope.fingerprint = ['timeline.stream.reconnect_exhausted'];
          },
        );
        // 無言の「ライブ更新が止まったまま」状態を state に出す。REST 取得済み
        // 投稿は残るので AsyncError にはせず、フラグだけ立てて UI が気付ける
        // ようにする。pull-to-refresh / タブ再選択の build() でクリアされる。
        final current = state.valueOrNull;
        if (current != null && !current.streamReconnectExhausted) {
          state = AsyncData(current.copyWith(streamReconnectExhausted: true));
        }
      },
    );
    _streamSubscription = stream.listen(
      (newPost) {
        final current = state.valueOrNull;
        if (current == null) return;
        if (newPost.filterAction == FilterAction.hide) return;
        final hideLivecure = ref.read(hideLivecureProvider);
        if (hideLivecure && _hasLivecureTag(newPost)) return;
        // Avoid duplicates.
        if (current.posts.any((p) => p.id == newPost.id)) return;
        if (_pendingPosts.any((p) => p.id == newPost.id)) return;

        if (_isNearTop) {
          // User is at or near the top — prepend immediately.
          state = AsyncData(
            current.copyWith(posts: [newPost, ...current.posts]),
          );
        } else {
          // User is scrolling — queue the post to avoid jumping.
          _pendingPosts.add(newPost);
          state = AsyncData(
            current.copyWith(pendingCount: _pendingPosts.length),
          );
        }
      },
      onError: (Object e, StackTrace st) {
        // controller 自体は error を流さない設計だが、adapter 側の .map
        // (_applyWordFilter 等) が投げると listener の error として届く。
        // 握り潰すと「ストリーミング来ない」だけになるので観測層へ流す
        // (#586)。state は AsyncError にせず (REST 投稿は生きている)
        // breadcrumb + throttle 付き captureException のみ。
        // throttle バケットは _lastListenCapture を独立に持つ (#602): connect
        // エラーの throttle に巻き込まれて listener 側の例外 (_applyWordFilter
        // 異常等) を取りこぼさないようにする。
        Sentry.addBreadcrumb(
          Breadcrumb(
            category: 'timeline.stream.listen',
            level: SentryLevel.warning,
            message: e.runtimeType.toString(),
          ),
        );
        final now = DateTime.now();
        if (_lastListenCapture != null &&
            now.difference(_lastListenCapture!) < _captureThrottle) {
          return;
        }
        _lastListenCapture = now;
        Sentry.captureException(
          scrubException(e),
          stackTrace: st,
          withScope: (scope) {
            scope.setTag('timeline.stream.listen', 'failed');
            scope.fingerprint = [
              'timeline.stream.listen',
              e.runtimeType.toString(),
            ];
          },
        );
      },
    );
  }

  /// Called by the UI when the user's scroll position changes.
  void setNearTop(bool nearTop) {
    _isNearTop = nearTop;
    if (nearTop) flushPending();
  }

  /// Flush queued posts into the timeline.
  void flushPending() {
    if (_pendingPosts.isEmpty) return;
    final current = state.valueOrNull;
    if (current == null) return;
    final merged = [..._pendingPosts.reversed, ...current.posts];
    _pendingPosts.clear();
    state = AsyncData(current.copyWith(posts: merged, pendingCount: 0));
  }

  static bool _hasLivecureTag(Post post) => hasLivecureTag(post);

  /// Replace a post in the list by ID (e.g. after reacting).
  void updatePost(Post updated) {
    final current = state.valueOrNull;
    if (current == null) return;
    final posts = current.posts.map((p) {
      if (p.id == updated.id) return updated;
      // Also check reblog target.
      if (p.reblog?.id == updated.id) {
        return p.copyWith(reblog: updated);
      }
      return p;
    }).toList();
    state = AsyncData(current.copyWith(posts: posts));
  }

  /// Remove a post from the list by ID (e.g. after deletion).
  void removePost(String id) {
    final current = state.valueOrNull;
    if (current == null) return;
    final posts = current.posts.where((p) => p.id != id).toList();
    state = AsyncData(current.copyWith(posts: posts));
  }

  /// Remove all posts by a user (e.g. after block/mute).
  void removePostsByUser(String userId) {
    final current = state.valueOrNull;
    if (current == null) return;
    final posts = current.posts.where((p) {
      if (p.author.id == userId) return false;
      if (p.reblog?.author.id == userId) return false;
      return true;
    }).toList();
    state = AsyncData(current.copyWith(posts: posts));
  }

  /// Load next page of posts (older posts).
  ///
  /// If an entire page is filtered out (e.g. word filters / mutes), skips
  /// ahead using the raw last ID until visible posts are found or the
  /// timeline is exhausted.
  ///
  /// On transient failure, retries up to [loadMoreMaxRetries] times with a short
  /// delay so that users who stay at the bottom of the list do not need to
  /// manually scroll up and back down.
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) {
      Sentry.addBreadcrumb(
        Breadcrumb(
          message: 'loadMore skipped',
          category: 'timeline',
          data: {
            'reason': current == null
                ? 'state_null'
                : current.isLoadingMore
                ? 'already_loading'
                : 'no_more',
            'postCount': current?.posts.length ?? 0,
          },
        ),
      );
      return;
    }

    state = AsyncData(current.copyWith(isLoadingMore: true));

    for (var attempt = 0; attempt <= loadMoreMaxRetries; attempt++) {
      try {
        final adapter = ref.read(currentAdapterProvider);
        final type = ref.read(selectedTimelineTypeProvider);
        if (adapter == null) {
          _resetLoading();
          return;
        }

        // Re-read state to get the latest posts (streaming may have added
        // new ones while we were waiting for a retry delay).
        final base = state.valueOrNull ?? current;
        String? maxId = base.posts.lastOrNull?.id;
        final allVisible = <Post>[];
        bool hasMore = true;
        // build() / fetchUntilVisible と同じ #601 ガード。全件 livecure な
        // ページが連続するサーバで client filter が allVisible を埋められず
        // 無限ページ取得 → レートリミット暴走になるのを防ぐ。
        var fetches = 0;

        while (hasMore && fetches < kMaxVisibilityPageFetches) {
          fetches++;
          final response = await adapter.getTimeline(
            type,
            query: TimelineQuery(maxId: maxId, limit: _pageSize),
          );

          // Report any conversion failures to Sentry for debugging.
          if (response.skippedPosts.isNotEmpty) {
            _reportSkippedPosts(response.skippedPosts, maxId);
          }

          // Use rawLastId to advance cursor even when all posts were skipped.
          final rawLast = response.rawLastId;
          if (response.posts.isEmpty) {
            if (rawLast != null && rawLast != maxId) {
              // Server had data but all conversions failed; advance cursor.
              hasMore = response.rawCount > 0;
              maxId = rawLast;
              if (hasMore) continue;
            }
            hasMore = false;
            break;
          }

          hasMore = response.rawCount > 0;
          maxId = response.posts.last.id;

          final hideLivecure = ref.read(hideLivecureProvider);
          final visibleOlder = response.posts
              .where((p) => p.filterAction != FilterAction.hide)
              .where((p) => !hideLivecure || !_hasLivecureTag(p))
              .toList();
          allVisible.addAll(visibleOlder);

          // Stop when visible posts are found or the server has no more data.
          if (allVisible.isNotEmpty || !hasMore) break;
        }

        if (fetches >= kMaxVisibilityPageFetches &&
            allVisible.isEmpty &&
            hasMore) {
          _recordPageCapHit(
            site: 'loadMore',
            visibleCollected: 0,
            hasMore: true,
          );
        }

        final enrichedMore = await _enrichIsCat(allVisible);
        // Re-read state to preserve posts added by streaming during await.
        final latest = state.valueOrNull ?? current;
        state = AsyncData(
          latest.copyWith(
            posts: [...latest.posts, ...enrichedMore],
            isLoadingMore: false,
            hasMore: hasMore,
            loadMoreError: null,
          ),
        );
        return; // Success — exit retry loop.
      } catch (e, st) {
        if (attempt < loadMoreMaxRetries) {
          // Wait before retrying; keep isLoadingMore true so the spinner
          // stays visible and duplicate calls are blocked.
          await Future<void>.delayed(loadMoreRetryDelay);
          continue;
        }
        // Final attempt failed — report and surface the error.
        try {
          final failedMaxId = current.posts.lastOrNull?.id;
          Sentry.captureException(
            e,
            stackTrace: st,
            hint: Hint.withMap({
              'maxId': failedMaxId ?? 'null',
              'attempts': '${attempt + 1}',
            }),
          );
        } catch (_) {
          // Sentry failure must not block state recovery.
        }
        final latest = state.valueOrNull ?? current;
        state = AsyncData(
          latest.copyWith(isLoadingMore: false, loadMoreError: e),
        );
      }
    }
  }

  /// Report posts that failed conversion to Sentry for debugging.
  /// Only sends post IDs and error messages — never post content.
  void _reportSkippedPosts(List<SkippedPost> skipped, String? maxId) {
    try {
      for (final post in skipped) {
        Sentry.captureMessage(
          'Post conversion failed',
          level: SentryLevel.warning,
          params: [post.id, post.error],
          hint: Hint.withMap({
            'skippedPostId': post.id,
            'conversionError': post.error,
            'maxId': maxId ?? 'null',
          }),
        );
      }
    } catch (_) {
      // Sentry failure must not affect timeline loading.
    }
  }

  /// Reset isLoadingMore to false, preserving the latest state.
  void _resetLoading() {
    final latest = state.valueOrNull;
    if (latest == null) return;
    state = AsyncData(latest.copyWith(isLoadingMore: false));
  }

  /// モロヘイヤの `POST /account/is_cat` を使い、投稿者の isCat フラグを補完する。
  /// Misskey adapter から取得した投稿は既に isCat が設定されているため、
  /// ここでは Mastodon adapter 経由の投稿のみを対象とする。
  Future<List<Post>> _enrichIsCat(List<Post> posts) async {
    final mulukhiya = ref.read(currentMulukhiyaProvider);
    final account = ref.read(currentAccountProvider);
    if (mulukhiya == null || account == null) return posts;

    // isCat が未設定（false）かつキャッシュにない acct を収集
    final accts = <String>{};
    for (final p in posts) {
      for (final user in [p.author, if (p.reblog != null) p.reblog!.author]) {
        if (!user.isCat && user.host != null) {
          final acct = '${user.username}@${user.host}';
          if (!_isCatCache.containsKey(acct)) accts.add(acct);
        }
      }
    }
    if (accts.isEmpty) return posts;

    final result = await mulukhiya.fetchIsCat(
      accessToken: account.userSecret.accessToken,
      accts: accts.toList(),
    );

    // 通信エラー時はキャッシュせず、次回再問い合わせ
    if (result == null) return posts;

    // 確定した結果のみキャッシュ（null = 取得失敗はキャッシュしない）
    for (final entry in result.entries) {
      if (entry.value != null) {
        _isCatCache[entry.key] = entry.value!;
      }
    }

    // isCat == true のユーザーがいなければ再構築不要
    if (!_isCatCache.values.any((v) => v)) return posts;

    return posts.map((p) => _applyIsCat(p)).toList();
  }

  Post _applyIsCat(Post p) {
    final author = _maybeCatUser(p.author);
    final reblog = p.reblog != null ? _applyIsCat(p.reblog!) : null;
    if (identical(author, p.author) && identical(reblog, p.reblog)) return p;
    return p.copyWith(author: author, reblog: reblog);
  }

  User _maybeCatUser(User user) {
    if (user.isCat || user.host == null) return user;
    final acct = '${user.username}@${user.host}';
    final isCat = _isCatCache[acct] ?? false;
    return isCat ? user.copyWithIsCat(true) : user;
  }
}

final timelineProvider =
    AsyncNotifierProvider.autoDispose<TimelineNotifier, TimelineState>(
      TimelineNotifier.new,
    );

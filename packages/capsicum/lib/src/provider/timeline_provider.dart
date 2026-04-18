import 'dart:async';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'account_manager_provider.dart';
import 'preferences_provider.dart';

/// Currently selected timeline type.
final selectedTimelineTypeProvider = StateProvider<TimelineType>(
  (ref) => TimelineType.home,
);

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

  const TimelineState({
    this.posts = const [],
    this.isLoadingMore = false,
    this.hasMore = true,
    this.loadMoreError,
    this.pendingCount = 0,
  });

  TimelineState copyWith({
    List<Post>? posts,
    bool? isLoadingMore,
    bool? hasMore,
    Object? loadMoreError,
    int? pendingCount,
  }) => TimelineState(
    posts: posts ?? this.posts,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    hasMore: hasMore ?? this.hasMore,
    loadMoreError: loadMoreError,
    pendingCount: pendingCount ?? this.pendingCount,
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

    while (hasMore) {
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

  void _startStreaming(StreamSupport adapter, TimelineType type) {
    _streamSubscription?.cancel();
    final stream = adapter.streamTimeline(type);
    _streamSubscription = stream.listen((newPost) {
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
        state = AsyncData(current.copyWith(posts: [newPost, ...current.posts]));
      } else {
        // User is scrolling — queue the post to avoid jumping.
        _pendingPosts.add(newPost);
        state = AsyncData(current.copyWith(pendingCount: _pendingPosts.length));
      }
    });
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
        return Post(
          id: p.id,
          postedAt: p.postedAt,
          author: p.author,
          content: p.content,
          scope: p.scope,
          attachments: p.attachments,
          favouriteCount: p.favouriteCount,
          reblogCount: p.reblogCount,
          replyCount: p.replyCount,
          quoteCount: p.quoteCount,
          favourited: p.favourited,
          reblogged: p.reblogged,
          bookmarked: p.bookmarked,
          reactions: p.reactions,
          myReaction: p.myReaction,
          reactionEmojis: p.reactionEmojis,
          inReplyToId: p.inReplyToId,
          reblog: updated,
        );
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

        while (hasMore) {
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
    return Post(
      id: p.id,
      postedAt: p.postedAt,
      author: author,
      content: p.content,
      scope: p.scope,
      attachments: p.attachments,
      favouriteCount: p.favouriteCount,
      reblogCount: p.reblogCount,
      replyCount: p.replyCount,
      quoteCount: p.quoteCount,
      favourited: p.favourited,
      reblogged: p.reblogged,
      bookmarked: p.bookmarked,
      sensitive: p.sensitive,
      reactions: p.reactions,
      myReaction: p.myReaction,
      reactionEmojis: p.reactionEmojis,
      inReplyToId: p.inReplyToId,
      reblog: reblog,
      quote: p.quote,
      quoteState: p.quoteState,
      spoilerText: p.spoilerText,
      emojis: p.emojis,
      emojiHost: p.emojiHost,
      card: p.card,
      poll: p.poll,
      filterAction: p.filterAction,
      filterTitle: p.filterTitle,
      pinned: p.pinned,
      channelId: p.channelId,
      channelName: p.channelName,
      localOnly: p.localOnly,
      quotable: p.quotable,
      language: p.language,
      url: p.url,
    );
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

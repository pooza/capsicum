import 'dart:async';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'account_manager_provider.dart';

/// Currently selected timeline type.
final selectedTimelineTypeProvider = StateProvider<TimelineType>(
  (ref) => TimelineType.home,
);

/// Paginated timeline state.
class TimelineState {
  final List<Post> posts;
  final bool isLoadingMore;
  final bool hasMore;

  const TimelineState({
    this.posts = const [],
    this.isLoadingMore = false,
    this.hasMore = true,
  });

  TimelineState copyWith({
    List<Post>? posts,
    bool? isLoadingMore,
    bool? hasMore,
  }) => TimelineState(
    posts: posts ?? this.posts,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    hasMore: hasMore ?? this.hasMore,
  );
}

/// Notifier that manages paginated timeline fetching with optional streaming.
class TimelineNotifier extends AutoDisposeAsyncNotifier<TimelineState> {
  static const _pageSize = 20;
  StreamSubscription<Post>? _streamSubscription;

  @override
  Future<TimelineState> build() async {
    final adapter = ref.watch(currentAdapterProvider);
    final type = ref.watch(selectedTimelineTypeProvider);
    if (adapter == null) return const TimelineState();

    // Initial REST fetch.
    final response = await adapter.getTimeline(
      type,
      query: const TimelineQuery(limit: _pageSize),
    );

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

    final visible = response.posts
        .where((p) => p.filterAction != FilterAction.hide)
        .toList();
    return TimelineState(
      posts: visible,
      hasMore: response.rawCount >= _pageSize,
    );
  }

  void _startStreaming(StreamSupport adapter, TimelineType type) {
    _streamSubscription?.cancel();
    final stream = adapter.streamTimeline(type);
    _streamSubscription = stream.listen((newPost) {
      final current = state.valueOrNull;
      if (current == null) return;
      if (newPost.filterAction == FilterAction.hide) return;
      // Prepend new post, avoiding duplicates.
      if (current.posts.any((p) => p.id == newPost.id)) return;
      state = AsyncData(current.copyWith(posts: [newPost, ...current.posts]));
    });
  }

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

  /// Load next page of posts (older posts).
  ///
  /// If an entire page is filtered out (e.g. word filters / mutes), skips
  /// ahead using the raw last ID until visible posts are found or the
  /// timeline is exhausted.
  ///
  /// --- 調査メモ (#89 v0.6.0 でも 4-5 回スクロールで読み込み停止の報告あり) ---
  /// フィルタは無関係の可能性が高い。未調査の疑い箇所:
  ///  - catch ブロックが古い current で上書き → ストリーミング中の投稿消失
  ///  - Sentry.captureException 自体が失敗すると isLoadingMore: true 固定
  ///  - サーバーが空レスポンス → rawCount=0 → hasMore=false で永久停止
  ///  - L172 の state 再取得で async 中の状態変化とのレース
  /// 次回調査時は Sentry breadcrumb を仕込んで再現データを取ること。
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    try {
      final adapter = ref.read(currentAdapterProvider);
      final type = ref.read(selectedTimelineTypeProvider);
      if (adapter == null) {
        state = AsyncData(current.copyWith(isLoadingMore: false));
        return;
      }

      String? maxId = current.posts.lastOrNull?.id;
      final allVisible = <Post>[];
      bool hasMore = true;

      while (hasMore) {
        final response = await adapter.getTimeline(
          type,
          query: TimelineQuery(maxId: maxId, limit: _pageSize),
        );

        hasMore = response.rawCount >= _pageSize;

        final visibleOlder = response.posts
            .where((p) => p.filterAction != FilterAction.hide)
            .toList();
        allVisible.addAll(visibleOlder);

        if (response.posts.isEmpty) break;
        maxId = response.posts.last.id;

        // Stop when visible posts are found or the server has no more data.
        if (allVisible.isNotEmpty || !hasMore) break;
      }

      final updated = state.valueOrNull ?? current;
      state = AsyncData(
        updated.copyWith(
          posts: [...updated.posts, ...allVisible],
          isLoadingMore: false,
          hasMore: hasMore,
        ),
      );
    } catch (e, st) {
      final failedMaxId = current.posts.lastOrNull?.id;
      Sentry.captureException(
        e,
        stackTrace: st,
        hint: Hint.withMap({'maxId': failedMaxId ?? 'null'}),
      );
      state = AsyncData(current.copyWith(isLoadingMore: false));
    }
  }
}

final timelineProvider =
    AsyncNotifierProvider.autoDispose<TimelineNotifier, TimelineState>(
      TimelineNotifier.new,
    );

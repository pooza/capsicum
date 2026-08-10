import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';
import 'preferences_provider.dart';
import 'timeline_provider.dart';

/// Parse a pinned hashtag spec ("tag" or "tag+and1+and2") into parts.
(String, List<String>?) parseHashtagSpec(String spec) {
  final parts = spec.split('+');
  final primary = parts.first;
  final all = parts.length > 1 ? parts.sublist(1) : null;
  return (primary, all);
}

/// Format a display label for a hashtag spec.
String hashtagSpecLabel(String spec) => '#${spec.replaceAll('+', ' + #')}';

/// Notifier that manages paginated hashtag timeline fetching.
///
/// The family key is a hashtag spec: "tag" or "tag+and1+and2" where "+"
/// separates AND-matched tags (Mastodon `all[]` parameter).
class HashtagTimelineNotifier
    extends AutoDisposeFamilyAsyncNotifier<TimelineState, String>
    with TimelineListMutations<String> {
  static const _pageSize = 20;

  /// 自分の投稿をこのハッシュタグ TL の先頭へ楽観的に挿入する (#887)。
  ///
  /// ホーム TL の [TimelineNotifier.insertOwnPost] (#717) と同じ狙い。呼び出し側
  /// （[readVisibleTimelines]）が「投稿がこの TL のタグを実際に持っているか」を
  /// 判定済みで、ここでは重複と実況フィルタだけを見る。ハッシュタグ TL は
  /// streaming を張っていないため、これが無いと再取得まで自分の投稿が出ない。
  void insertOwnPost(Post post) {
    final current = state.valueOrNull;
    if (current == null) return;
    if (post.filterAction == FilterAction.hide) return;
    if (ref.read(hideLivecureProvider) && hasLivecureTag(post)) return;
    if (current.posts.any((p) => p.id == post.id)) return;
    state = AsyncData(current.copyWith(posts: [post, ...current.posts]));
  }

  @override
  Future<TimelineState> build(String arg) async {
    final adapter = ref.watch(currentAdapterProvider);
    final contextKey = timelineContextKey(
      ref.watch(currentAccountProvider)?.key,
      'tag:$arg',
    );
    if (adapter == null || adapter is! HashtagSupport) {
      return TimelineState(hasMore: false, contextKey: contextKey);
    }

    final (primary, all) = parseHashtagSpec(arg);
    final hideLivecure = ref.watch(hideLivecureProvider);
    final result = await fetchUntilVisible(
      pageSize: _pageSize,
      hideLivecure: hideLivecure,
      fetch: (maxId) => (adapter as HashtagSupport).getPostsByHashtag(
        primary,
        query: TimelineQuery(maxId: maxId, limit: _pageSize),
        all: all,
      ),
    );
    return result.copyWith(contextKey: contextKey);
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    for (var attempt = 0; attempt <= loadMoreMaxRetries; attempt++) {
      try {
        final adapter = ref.read(currentAdapterProvider);
        if (adapter == null || adapter is! HashtagSupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }

        final (primary, all) = parseHashtagSpec(arg);
        final base = state.valueOrNull ?? current;
        final lastId = base.posts.last.id;
        final hideLivecure = ref.read(hideLivecureProvider);
        final raw = await (adapter as HashtagSupport).getPostsByHashtag(
          primary,
          query: TimelineQuery(maxId: lastId, limit: _pageSize),
          all: all,
        );
        final older = hideLivecure
            ? raw.where((p) => !hasLivecureTag(p)).toList()
            : raw;

        // 既にリストにある投稿は落とす (#909)。各行は id をキーにしているので、
        // ページ境界の重複をそのまま足すと Duplicate keys で描画ごと落ちる。
        final knownIds = {for (final p in base.posts) p.id};
        final appended = older.where((p) => knownIds.add(p.id)).toList();
        state = AsyncData(
          base.copyWith(
            posts: [...base.posts, ...appended],
            isLoadingMore: false,
            hasMore: raw.length >= _pageSize,
            loadMoreError: null,
          ),
        );
        return;
      } catch (e) {
        if (attempt < loadMoreMaxRetries) {
          await Future<void>.delayed(loadMoreRetryDelay);
          continue;
        }
        // 最終失敗時は loadMoreError を立て、トリガー側の再試行抑止を効かせる
        // (#678、TimelineState / list_provider と同型の番兵パターン)。
        state = AsyncData(
          (state.valueOrNull ?? current).copyWith(
            isLoadingMore: false,
            loadMoreError: e,
          ),
        );
      }
    }
  }
}

final hashtagTimelineProvider = AsyncNotifierProvider.autoDispose
    .family<HashtagTimelineNotifier, TimelineState, String>(
      HashtagTimelineNotifier.new,
    );

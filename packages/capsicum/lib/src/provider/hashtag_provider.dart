import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/account_key.dart';
import '../ui/widget/content_parser.dart';
import 'account_manager_provider.dart';
import 'preferences_provider.dart';
import 'timeline_provider.dart';

/// タグの入力欄に出す、AND 指定の案内 (#1238)。
///
/// ⚠ タブの追加とデッキのカラムの追加に同じ欄があるので、文面を 2 か所に書かない。
const kHashtagAndHelperText = '+ でつなぐと AND（例: nitiasa+precure）';

/// spec の表示ラベル (#1209)。
///
/// | 条件 | ラベル |
/// | --- | --- |
/// | a かつ b | `#a + #b` |
/// | a または b | `#a / #b` |
/// | a かつ（b または c）・d は除く | `#a + (#b / #c) − #d` |
///
/// ⚠ 割り方の正本は [HashtagQuery.parse]（capsicum_core・#1159）。
String hashtagSpecLabel(String spec) {
  final query = HashtagQuery.parse(spec);
  String tags(List<String> list, String separator) =>
      list.map((t) => '#$t').join(separator);
  final any = tags(query.any, ' / ');
  return [
    [
      if (query.all.isNotEmpty) tags(query.all, ' + '),
      if (query.any.isNotEmpty) query.all.isEmpty ? any : '($any)',
    ].join(' + '),
    for (final tag in query.none) '− #$tag',
  ].join(' ');
}

/// [post] が、タグ TL の条件 [query] の除外に当たるか (#1209)。
///
/// ⚠ **サーバーが除外を受けられない SNS（Misskey）のための、端末側の絞り込み。**
/// Mastodon はサーバーが `none[]` で落として返すので、ここでは何も落ちない。
/// ⚠ ブースト / リノートは中身の投稿のタグで見る（外側はタグを持たない）。
bool postExcludedByHashtagQuery(Post post, HashtagQuery query) =>
    query.none.isNotEmpty && query.excludes(postHashtags(post.reblog ?? post));

/// [post] を、タグ TL の条件 [query] の一覧に残すか (#1209 / #1283)。
///
/// サーバーが返した一覧への、端末側の確かめ直し。落とすのは 2 つ:
///
/// - 除外のタグを持つ投稿（[postExcludedByHashtagQuery]・Misskey のため）
/// - 「すべて含む」のタグを欠く投稿（Mastodon は、サーバーに実在しないタグを
///   `all[]` から黙って落として AND を外す。[HashtagQuery.lacksRequired]）
///
/// ⚠ ブースト / リノートは中身の投稿のタグで見る（外側はタグを持たない）。
bool postKeptByHashtagQuery(Post post, HashtagQuery query) {
  if (postExcludedByHashtagQuery(post, query)) return false;
  // ⚠ タグ 1 つだけの TL は確かめない（[HashtagQuery.lacksRequired]）。
  if (query.singleTag != null) return true;
  return !query.lacksRequired(postHashtags(post.reblog ?? post));
}

/// ハッシュタグ TL の family キー (#1088)。
///
/// [spec] は "tag" または "tag+and1+and2"（"+" は AND 指定・Mastodon の `all[]`）。
///
/// ⚠ **アカウントを含める。**含めないと、デッキで 2 アカウントの同じタグを並べた
/// ときに**同じインスタンスを共有して、片方のサーバーの投稿がもう片方に混ざる**
/// （設計書 B-4）。record は値で比較されるので、そのまま family キーになる。
typedef HashtagTimelineKey = ({AccountKey? account, String spec});

/// Notifier that manages paginated hashtag timeline fetching.
class HashtagTimelineNotifier
    extends AutoDisposeFamilyAsyncNotifier<TimelineState, HashtagTimelineKey>
    with
        TimelineListMutations<HashtagTimelineKey>,
        TimelineLiveIngest<HashtagTimelineKey> {
  static const _pageSize = 20;

  /// ハッシュタグ TL は `public`（Mastodon Web と同じ・#1289）。
  @override
  FilterContext get filterContext => FilterContext.public;

  @override
  String get liveStreamKey =>
      timelineContextKey(arg.account, HashtagTab(arg.spec))!;

  @override
  TabType get liveStreamTab => HashtagTab(arg.spec);

  @override
  String? get liveHost => arg.account?.host;

  @override
  int get catchUpPageSize => _pageSize;

  /// ⚠ `getPostsByHashtag` は生のサーバー件数を返さない（本線 TL の
  /// `getTimeline` だけが [TimelineResponse] を返す）。フィルタ後の件数を
  /// `rawCount` に使うので、**サーバーが満ページを返したのに手元で削られた回は
  /// 1 ページで打ち切る**。ギャップの古い側を取りこぼしうるが、次の live 遷移と
  /// pull-to-refresh で埋まる。
  @override
  Future<CatchUpPage?> fetchCatchUpPage(String? maxId) async {
    final adapter = adapterForTimelineKey(
      ref.read(currentAccountProvider),
      arg.account,
    );
    if (adapter == null || adapter is! HashtagSupport) return null;
    final raw = await (adapter as HashtagSupport).getPostsByHashtag(
      _query,
      query: TimelineQuery(maxId: maxId, limit: _pageSize),
    );
    // ⚠ 続きがあるかは絞る前の件数で見る（除外で薄くなったページを最後の
    // ページと読まない・#1209）。
    return (
      posts: raw.where(_keeps).toList(),
      rawCount: raw.length,
      rawLastId: raw.lastOrNull?.id,
    );
  }

  /// この TL の条件 (#1209)。
  HashtagQuery get _query => HashtagQuery.parse(arg.spec);

  /// サーバーが返した投稿を、条件で確かめ直す (#1209 / #1283)。
  bool _keeps(Post post) => postKeptByHashtagQuery(post, _query);

  @override
  bool acceptsLivePost(Post post) => _keeps(post);

  /// 自分の投稿をこのハッシュタグ TL の先頭へ楽観的に挿入する (#887)。
  ///
  /// ホーム TL の [TimelineNotifier.insertOwnPost] (#717) と同じ狙い。呼び出し側
  /// （[readVisibleTimelines]）が「投稿がこの TL のタグを実際に持っているか」を
  /// 判定済みで、ここでは重複と実況フィルタだけを見る。ハッシュタグ TL は
  /// streaming を張っていないため、これが無いと再取得まで自分の投稿が出ない。
  void insertOwnPost(Post post) {
    final current = state.valueOrNull;
    if (current == null) return;
    if (post.isHiddenIn(filterContext)) return;
    if (ref.read(hideLivecureProvider) && hasLivecureTag(post)) return;
    if (current.posts.any((p) => p.id == post.id)) return;
    // ライブ購読 (#1098) が入ったので、未表示バッファに居るぶんも重複になる。
    if (hasPendingPost(post.id)) return;
    // ⚠ 自分の投稿は位置に関わらず即座に先頭へ出す（意図的に near-top を見ない）。
    seedLiveIngestAnchor([post, ...current.posts]);
    state = AsyncData(current.copyWith(posts: [post, ...current.posts]));
  }

  @override
  Future<TimelineState> build(HashtagTimelineKey key) async {
    _olderCursor = null;
    // 前のタグ / アカウントの新着を、このカラムへ漏らさない (#1098)。
    final liveGeneration = resetLiveIngestState();
    // 🔴 `Account` 全体ではなく、解決したアダプタだけを見る（本線の
    // `TimelineNotifier.build` と同じ理由。全体を見ると、復帰のたびに読み直す）。
    final adapter = watchAdapterForTimelineKey(ref, key.account);
    final contextKey = timelineContextKey(key.account, HashtagTab(key.spec));
    if (adapter == null || adapter is! HashtagSupport) {
      return TimelineState(hasMore: false, contextKey: contextKey);
    }

    // ⚠ 配線は取得の前。トグルは watch しない（切替が build() 全体を誘発して
    // 可視のジャンプになる・#904）。初回接続は取得の後に張る。
    if (adapter is StreamSupport) {
      final streamAdapter = adapter as StreamSupport;
      ref.onDispose(() => disposeLiveStream(streamAdapter));
      listenLiveStreamToggle(streamAdapter);
    }

    final condition = HashtagQuery.parse(key.spec);
    final hideLivecure = ref.watch(hideLivecureProvider);
    final result = await fetchUntilVisible(
      filterContext: filterContext,
      pageSize: _pageSize,
      hideLivecure: hideLivecure,
      fetch: (maxId) => (adapter as HashtagSupport).getPostsByHashtag(
        condition,
        query: TimelineQuery(maxId: maxId, limit: _pageSize),
      ),
      keep: (post) => postKeptByHashtagQuery(post, condition),
      // ⚠ 上限まで引いて 1 件も残らなかった回も、進めたぶんを続き読みへ渡す
      // (#1283)。渡さないと [loadMore] が先頭から引き直し、その先へ進めない。
      onRawCursor: (rawLastId) => _olderCursor = rawLastId,
    );
    seedLiveIngestAnchor(result.posts);
    if (adapter is StreamSupport) {
      startLiveStreamIfEnabled(
        adapter as StreamSupport,
        generation: liveGeneration,
      );
    }
    return result.copyWith(
      contextKey: contextKey,
      streamConnectionState: streamConnectionState,
    );
  }

  /// 続き読みの、**絞る前の**末尾の id（次に引く起点）。
  ///
  /// ⚠⚠ **表示中の最後の投稿を起点にしない。**除外（Misskey は端末側で絞る・
  /// #1209）や実況フィルタで 1 ページぶんが丸ごと落ちると、表示中の最後は
  /// 動かないので、同じページを引き直し続けて先へ進めなくなる（v2.2 の
  /// リリース前レビュー）。初回取得と取りこぼしの補いは、もとから生の末尾で
  /// 進んでいる。
  String? _olderCursor;

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    for (var attempt = 0; attempt <= loadMoreMaxRetries; attempt++) {
      try {
        final adapter = adapterForTimelineKey(
          ref.read(currentAccountProvider),
          arg.account,
        );
        if (adapter == null || adapter is! HashtagSupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }

        final hideLivecure = ref.read(hideLivecureProvider);
        var cursor =
            _olderCursor ?? (state.valueOrNull ?? current).posts.lastOrNull?.id;
        final older = <Post>[];
        var hasMore = true;
        // ⚠ 絞った結果が空のページは、上限まで続けて先を引く。空のまま返すと、
        // 画面には何も足されないので、続きを読む合図が二度と来ない。
        for (var page = 0; page < kMaxEmptyOlderPages; page++) {
          final raw = await (adapter as HashtagSupport).getPostsByHashtag(
            _query,
            query: TimelineQuery(maxId: cursor, limit: _pageSize),
          );
          if (raw.isNotEmpty) cursor = raw.last.id;
          older.addAll(
            raw
                .where(_keeps)
                .where((p) => !p.isHiddenIn(filterContext))
                .where((p) => !hideLivecure || !hasLivecureTag(p)),
          );
          hasMore = raw.length >= _pageSize;
          if (older.isNotEmpty || !hasMore) break;
        }
        _olderCursor = cursor;

        // 既にリストにある投稿は落とす (#909)。各行は id をキーにしているので、
        // ページ境界の重複をそのまま足すと Duplicate keys で描画ごと落ちる。
        final base = state.valueOrNull ?? current;
        final knownIds = {for (final p in base.posts) p.id};
        final appended = older.where((p) => knownIds.add(p.id)).toList();
        state = AsyncData(
          base.copyWith(
            posts: [...base.posts, ...appended],
            isLoadingMore: false,
            hasMore: hasMore,
            loadMoreError: null,
            // 上限（[kMaxEmptyOlderPages]）まで引いても見える投稿が出なかった。
            // 末尾に「さらに古い投稿を探す」を出す (#1292)。
            pageCapHit: older.isEmpty && hasMore,
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
    .family<HashtagTimelineNotifier, TimelineState, HashtagTimelineKey>(
      HashtagTimelineNotifier.new,
      dependencies: [currentAccountProvider],
    );

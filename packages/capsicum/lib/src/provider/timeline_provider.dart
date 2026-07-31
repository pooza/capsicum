import 'dart:async';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../main.dart' show appLaunchStopwatch;
import '../model/account_key.dart';
import '../service/timeline_cache.dart';
import '../util/exception_scrub.dart';
import '../util/startup_trace.dart';
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

/// 表示中の TL がどの文脈で取得されたかを表すキーを組み立てる (#758)。
///
/// [kind] は TL の種別を表す識別子（メイン TL は `tl:<type>`、ハッシュタグは
/// `tag:<spec>`、リストは `list:<id>`）。アカウントキーが無いときは null。
/// provider 側は build() でこのキーを TimelineState に刻み、UI 側は現在の文脈から
/// 同じ式で組み立てたキーと照合する。両者で同一の式を使うことが前提。
String? timelineContextKey(AccountKey? accountKey, String kind) =>
    accountKey == null ? null : '${accountKey.toStorageKey()}|$kind';

/// 自分の投稿が、指定した TL 種別に実際に載るかを判定する (#814)。
/// 楽観挿入 ([TimelineNotifier.insertOwnPost]) が、載らないはずの投稿
/// （例: ローカル/連合を見ているときの unlisted・フォロワー限定）を先頭へ
/// 差し込んで「リフレッシュで消える幻の投稿」を作らないためのゲート。
///
/// - **home / social**（Misskey hybrid = home + local）: 自分の投稿は direct
///   以外の全公開範囲（public / unlisted / followersOnly）が載る。
/// - **local / federated**: 公開系 TL は `public` のみを表示し、unlisted
///   （Misskey の home 相当）・followersOnly は載らない。federated（連合 /
///   グローバル）はさらに `localOnly` 投稿を除く（連合しないため）。
/// - **directMessages**: DM 一覧は楽観挿入の対象外（direct は元々挿入しない）。
///
/// 各種別のエンドポイント対応は Mastodon / Misskey アダプタの `getTimeline`
/// 参照（local=public?local / local-timeline、federated=public / global）。
bool ownPostAppearsInTimeline(TimelineType type, Post post) {
  switch (type) {
    case TimelineType.home:
    case TimelineType.social:
      return post.scope != PostScope.direct;
    case TimelineType.local:
      return post.scope == PostScope.public;
    case TimelineType.federated:
      return post.scope == PostScope.public && !post.localOnly;
    case TimelineType.directMessages:
      return false;
  }
}

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

  /// REST ページ取得が [kMaxVisibilityPageFetches] の上限に到達して、可視投稿が
  /// 1 件も取れないまま打ち切られた状態 (#624)。実況フィルタ ON で全件除外
  /// された場合のサイレント終了を UI に出すための目印。
  /// `streamReconnectExhausted` と同じく pull-to-refresh / タブ再選択で
  /// build() が再実行されるとクリアされる。
  final bool pageCapHit;

  /// streaming のライブ接続状態 (#714)。backend の接続ライフサイクルを反映し、
  /// 常時インジケータの表示に使う。`exhausted` は `streamReconnectExhausted`
  /// の可視化と同じ枯渇状態を表す。build() 再実行で `connecting` に戻る。
  final StreamConnectionState streamConnectionState;

  /// この TimelineState がどの文脈（アカウント＋種別/タグ/リスト）で取得された
  /// かを表すキー (#758)。Riverpod は build() 再実行中も直前 state を valueOrNull
  /// に保持するため、文脈切替直後はこのキーが現在の文脈と食い違う「前の文脈の
  /// キャッシュ」が一瞬見えることがある。UI 側は現在の文脈キーと照合し、
  /// 食い違う state はそのまま描かずローディングへフォールバックする。
  final String? contextKey;

  /// このセッション（build() 以降）で streaming が切断→再接続を試みた回数 (#782)。
  /// インジケータに「ちょくちょく切れている」を**回数として正直に**出すための値。
  /// 速い再接続は色のちらつきだけだと目視できないため、累積回数で見えるようにする。
  /// build() 再実行（pull-to-refresh / 文脈切替）で 0 に戻る。
  final int reconnectCount;

  /// 直近で切断を検知した時刻 (#782)。インジケータの tooltip に「直近切断 HH:MM」
  /// として出し、フラップの新しさを判断できるようにする。build() でクリアされる。
  final DateTime? lastDisconnectedAt;

  /// ディスクキャッシュから先出しした状態 (#890)。サーバーに問い合わせる前の
  /// 「前回の続き」なので、既読位置復元 (#715) のような**一度きりの位置決め**は
  /// この状態では走らせない（直後に届く REST の結果で並びが変わるため）。
  final bool fromCache;

  const TimelineState({
    this.posts = const [],
    this.isLoadingMore = false,
    this.hasMore = true,
    this.loadMoreError,
    this.pendingCount = 0,
    this.streamReconnectExhausted = false,
    this.pageCapHit = false,
    this.streamConnectionState = StreamConnectionState.connecting,
    this.contextKey,
    this.reconnectCount = 0,
    this.lastDisconnectedAt,
    this.fromCache = false,
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
    bool? pageCapHit,
    StreamConnectionState? streamConnectionState,
    String? contextKey,
    int? reconnectCount,
    DateTime? lastDisconnectedAt,
    bool? fromCache,
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
    pageCapHit: pageCapHit ?? this.pageCapHit,
    streamConnectionState: streamConnectionState ?? this.streamConnectionState,
    contextKey: contextKey ?? this.contextKey,
    reconnectCount: reconnectCount ?? this.reconnectCount,
    lastDisconnectedAt: lastDisconnectedAt ?? this.lastDisconnectedAt,
    fromCache: fromCache ?? this.fromCache,
  );
}

/// 投稿 id を「新しい順（降順）」で比較する (#781)。タイムラインは Mastodon /
/// Misskey とも id 降順で並ぶ前提（loadMore の maxId カーソルもこれに依存）。
/// ギャップ補完で取り込んだ投稿を既存リストへ正しい位置に差し込むために使う。
///
/// Mastodon の id は数値（snowflake・桁が伸びるため文字列比較では不正確）なので
/// BigInt で比較し、Misskey の aid（辞書順で時系列）はそのまま文字列比較する。
/// 同一サーバーのタイムライン内で両形式が混ざることはない。
int comparePostIdDesc(String a, String b) {
  final na = BigInt.tryParse(a);
  final nb = BigInt.tryParse(b);
  if (na != null && nb != null) return nb.compareTo(na);
  return b.compareTo(a);
}

/// 1 ページぶんの catch-up 取得結果（新しい順の投稿・生サーバー件数・最古 id）。
typedef CatchUpPage = ({List<Post> posts, int rawCount, String? rawLastId});

/// live 復帰時のギャップ補完 (#781/#784) のページング本体。provider 依存から
/// 切り離した純粋関数で、`fetchUntilVisible` と同じく [fetch] 注入でテスト可能。
///
/// [since] より新しい投稿だけを **新しい順** で集めて返す（重複除去済み）。
/// 重要: サーバーには **maxId のみ** を渡して常に DESC で取得する。Misskey は
/// `sinceId` 単独指定だと結果が ASC（古い順）になり（本家 QueryService の
/// `makePaginationQuery`: sinceId のみ → ASC / sinceId+untilId → DESC）、
/// 「最古 id を次ページの maxId にして下へ」という DESC 前提のページングが壊れて
/// ギャップの新しい側を取りこぼす。そこで since 到達はクライアント側で判定する
/// （Mastodon は元から DESC なので無影響）。
///
/// [since] が null（アンカー未確立）のときは最新ページ 1 枚だけ取得してシードする。
@visibleForTesting
Future<List<Post>> collectCatchUpGap({
  required String? since,
  required int pageSize,
  required int maxFetches,
  required Future<CatchUpPage> Function(String? maxId) fetch,
}) async {
  final gap = <Post>[];
  final gapIds = <String>{};
  String? maxId;
  var fetches = 0;
  while (fetches < maxFetches) {
    fetches++;
    final page = await fetch(maxId);
    var reachedAnchor = false;
    for (final post in page.posts) {
      // since 以下（= 既知）に達したら、posts は新しい順なので残りも既知。
      // since 自身も既知なので等しい場合も含めて打ち切る。
      if (since != null && comparePostIdDesc(post.id, since) >= 0) {
        reachedAnchor = true;
        break;
      }
      if (gapIds.add(post.id)) gap.add(post);
    }
    // since が無いときは最新ページ 1 枚だけシードする。全件フィルタ TL で毎 live
    // フルページ走査するのを防ぎ、REST→live 窓の取りこぼしだけ拾えれば十分。
    if (since == null) break;
    // since まで読み切った、または満ページ未満（これ以上古い投稿が無い）なら停止。
    if (reachedAnchor) break;
    final rawLast = page.rawLastId ?? page.posts.lastOrNull?.id;
    if (page.rawCount < pageSize || rawLast == null) break;
    maxId = rawLast; // さらに古い方（下）へページング。
  }
  return gap;
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

  final pageCapHit =
      fetches >= kMaxVisibilityPageFetches && allVisible.isEmpty && hasMore;
  if (pageCapHit) {
    _recordPageCapHit(
      site: 'fetchUntilVisible',
      visibleCollected: 0,
      hasMore: true,
    );
  }

  return TimelineState(
    posts: allVisible,
    hasMore: hasMore,
    pageCapHit: pageCapHit,
  );
}

/// ハッシュタグ / リスト / チャンネルの各 TL に、ホーム TL と同じ「表示中の
/// リストを手元で直す」操作を持たせる (#887)。
///
/// 削除・再投稿・リアクション等の結果は [TimelineNotifier] にしか反映されて
/// おらず、ハッシュタグタブやリストタブを見ているときは画面が変わらないまま
/// だった（タブを切り替えると再取得が走って初めて反映される）。表示中の TL が
/// どれであっても同じ操作を適用できるよう、共通の変更手段をここに置く。
mixin TimelineListMutations<Arg>
    on AutoDisposeFamilyAsyncNotifier<TimelineState, Arg> {
  /// 削除された投稿を一覧から取り除く。
  void removePost(String id) {
    final current = state.valueOrNull;
    if (current == null) return;
    final posts = current.posts.where((p) => p.id != id).toList();
    if (posts.length == current.posts.length) return;
    state = AsyncData(current.copyWith(posts: posts));
  }

  /// 内容が変わった投稿を差し替える（ブースト取り消し等）。
  void updatePost(Post updated) {
    final current = state.valueOrNull;
    if (current == null) return;
    final posts = current.posts.map((p) {
      if (p.id == updated.id) return updated;
      if (p.reblog?.id == updated.id) return p.copyWith(reblog: updated);
      return p;
    }).toList();
    state = AsyncData(current.copyWith(posts: posts));
  }

  /// ブロック / ミュートした相手の投稿を一覧から取り除く。
  ///
  /// 本線 TL 側 ([TimelineNotifier.removePostsByUser]) と同じ判定。ブースト元の
  /// 投稿者も見るのは、ブロックした相手をブーストした第三者の投稿が残ると、
  /// 「ブロックしたのに本文が見え続ける」状態になるため。
  void removePostsByUser(String userId) {
    final current = state.valueOrNull;
    if (current == null) return;
    final posts = current.posts.where((p) {
      if (p.author.id == userId) return false;
      if (p.reblog?.author.id == userId) return false;
      return true;
    }).toList();
    if (posts.length == current.posts.length) return;
    state = AsyncData(current.copyWith(posts: posts));
  }
}

/// Notifier that manages paginated timeline fetching with optional streaming.
class TimelineNotifier extends AutoDisposeAsyncNotifier<TimelineState> {
  static const _pageSize = 20;

  /// ホーム TL の初回描画を 1 プロセス 1 回だけ計測するためのフラグ (#716)。
  /// AutoDispose で Notifier は作り直されるため static に持つ。
  static bool _homeFirstPaintReported = false;
  StreamSubscription<Post>? _streamSubscription;
  final List<Post> _pendingPosts = [];
  final Map<String, bool> _isCatCache = {};
  bool _isNearTop = true;

  /// provider が破棄済みか (#890)。キャッシュ先出しの裏で走る初回取得が、
  /// 破棄後に state を触らないようにするための番兵。build() のたびに false へ
  /// 戻す（`ref.onDispose` は破棄だけでなく **再計算のたび**にも呼ばれるため、
  /// 立てっぱなしにすると以降の publish が全部止まる）。
  bool _disposed = false;

  /// build() の世代 (#890)。キャッシュ先出しの裏で走る取得が、その後の再計算で
  /// 置き換わった state を古い結果で上書きしないようにする。
  int _buildGeneration = 0;

  /// 起動時キャッシュの先出しは 1 プロセス 1 回だけ (#890)。セッション中のタブ /
  /// アカウント切替で古い一覧が一瞬出るのを防ぐ。AutoDispose で Notifier は
  /// 作り直されるため static に持つ（[_homeFirstPaintReported] と同じ理由）。
  static bool _startupCacheServed = false;

  /// テストから「起動直後」の状態に戻すためのフック。プロセス 1 回の制約
  /// （[_startupCacheServed] / [_homeFirstPaintReported]）を解除する。
  @visibleForTesting
  static void resetStartupStateForTesting() {
    _startupCacheServed = false;
    _homeFirstPaintReported = false;
  }

  /// 既知の最新投稿 id（先頭）。streaming 再接続時のギャップ補完 (#781) で
  /// `since_id` の起点に使う。state.valueOrNull を直接読むと build / 接続コール
  /// バックのレースで null を踏みうるため、prepend のたびにここへ更新して保持する。
  String? _newestKnownId;

  /// ギャップ補完 (#781) の多重実行ガード。`live` 遷移が連続しても 1 本に絞る。
  bool _catchUpInProgress = false;

  /// 切断検知回数・直近切断時刻 (#782)。インジケータへ正直に出すため notifier 側
  /// で数え、state に反映する。build() でリセット。
  int _reconnectCount = 0;
  DateTime? _lastDisconnectedAt;

  /// streaming 接続状態の真実の値 (#714)。build() 中（state がまだ
  /// AsyncLoading で valueOrNull が null）に live 等が発火しても取りこぼさない
  /// よう、callback はここへ常時記録し、build() の返り値にもこの値を反映する。
  StreamConnectionState _streamConnectionState =
      StreamConnectionState.connecting;

  @override
  Future<TimelineState> build() async {
    // build() reruns when adapter / timeline type changes. Reset stream-side
    // state so queued posts from a previous timeline context cannot leak
    // into the new one via flushPending().
    _pendingPosts.clear();
    _isNearTop = true;
    _disposed = false;
    final generation = ++_buildGeneration;
    _streamConnectionState = StreamConnectionState.connecting;
    _newestKnownId = null;
    _catchUpInProgress = false;
    _reconnectCount = 0;
    _lastDisconnectedAt = null;

    final adapter = ref.watch(currentAdapterProvider);
    final type = ref.watch(selectedTimelineTypeProvider);
    final contextKey = timelineContextKey(
      ref.watch(currentAccountProvider)?.key,
      'tl:${type.name}',
    );
    if (adapter == null) return TimelineState(contextKey: contextKey);

    // #716 計測: ホーム TL の初回描画を fetch (サーバー応答) / enrich (isCat) /
    // since-launch に分けて測る。fetch はサーバー負荷依存・enrich は item3 の
    // 遅延化候補・since-launch は #716 復元並列化の効果を含む全体前段。1 回だけ。
    final measureHomePaint =
        type == TimelineType.home && !_homeFirstPaintReported;
    final hideLivecure = ref.watch(hideLivecureProvider);

    ref.onDispose(() {
      _disposed = true;
      _streamSubscription?.cancel();
      if (adapter is StreamSupport) {
        (adapter as StreamSupport).disposeStream();
      }
    });

    // ライブ更新トグルの購読は build() 側で張る（rebuild のたびに Riverpod が
    // 前回ぶんを破棄してくれる）。初回接続は取得完了後 ([_loadInitial]) に行う。
    if (adapter is StreamSupport) {
      final streamAdapter = adapter as StreamSupport;
      if (!ref.read(streamingEnabledProvider)) {
        _streamConnectionState = StreamConnectionState.disabled;
      }
      ref.listen(streamingEnabledProvider, (_, enabled) {
        if (enabled) {
          _setStreamConnectionState(StreamConnectionState.connecting);
          _startStreaming(streamAdapter, type);
        } else {
          _stopStreaming(streamAdapter);
        }
      });
    }

    // 起動直後の 1 回だけ、前回のホーム TL をディスクから先出しする (#890)。
    // 描画をサーバー応答から切り離し、REST は裏で追いついて置き換える。
    final cached = await _loadStartupCache(
      adapter: adapter,
      type: type,
      contextKey: contextKey,
      hideLivecure: hideLivecure,
      measureHomePaint: measureHomePaint,
    );
    if (cached != null) {
      unawaited(
        _loadInitialInBackground(
          adapter: adapter,
          type: type,
          contextKey: contextKey,
          hideLivecure: hideLivecure,
          generation: generation,
        ),
      );
      return cached;
    }

    return _loadInitial(
      adapter: adapter,
      type: type,
      contextKey: contextKey,
      hideLivecure: hideLivecure,
      measureHomePaint: measureHomePaint,
      publishToState: false,
      generation: generation,
    );
  }

  /// 初回スナップショットの取得本体。build() から直接 await されるか（キャッシュ
  /// 無し）、キャッシュ先出し後にバックグラウンドで走って state を差し替える
  /// （[publishToState]、#890）。ref.watch はここでは使わない（build 外でも走る
  /// ため）。必要な設定値は build() 側で watch して渡す。
  Future<TimelineState> _loadInitial({
    required DecentralizedBackendAdapter adapter,
    required TimelineType type,
    required String? contextKey,
    required bool hideLivecure,
    required bool measureHomePaint,
    required bool publishToState,
    required int generation,
  }) async {
    final fetchSw = measureHomePaint ? (Stopwatch()..start()) : null;

    // Initial REST fetch — retry pages until visible posts are found or the
    // timeline is exhausted (same logic as loadMore).
    final allVisible = <Post>[];
    // 次回起動の先出し用に、可視投稿と 1:1 の生 JSON を控える (#890)。
    final allRaw = <Map<String, dynamic>>[];
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

      // 生 JSON はサーバー応答と 1:1 なので、可視判定と同じループで拾って
      // 並びを保つ (#890)。rawJson を持たない経路では空のままで、その場合は
      // 単にキャッシュを書かない。
      for (var i = 0; i < response.posts.length; i++) {
        final post = response.posts[i];
        if (post.filterAction == FilterAction.hide) continue;
        if (hideLivecure && _hasLivecureTag(post)) continue;
        allVisible.add(post);
        if (i < response.rawJson.length) allRaw.add(response.rawJson[i]);
      }

      if (allVisible.isNotEmpty || !hasMore) break;
    }

    final pageCapHit =
        fetches >= kMaxVisibilityPageFetches && allVisible.isEmpty && hasMore;
    if (pageCapHit) {
      _recordPageCapHit(site: 'build', visibleCollected: 0, hasMore: true);
    }

    // ここから先は副作用（streaming 接続・キャッシュ保存・enrich）に入る。以前は
    // 破棄／世代のチェックが最後の state 差し替え直前にしか無く、キャッシュ先出しの
    // 裏で走っている間にアカウント切替・ログアウトが起きると、**捨てるはずの世代が
    // WebSocket を張り直したり、ログアウト直後にキャッシュを書き戻したり**していた。
    // 副作用の手前でも同じ条件で降りる。
    if (_isStale(generation, contextKey, publishToState: publishToState)) {
      return TimelineState(
        posts: allVisible,
        hasMore: hasMore,
        pageCapHit: pageCapHit,
        contextKey: contextKey,
        streamConnectionState: _streamConnectionState,
      );
    }

    // Start streaming if supported and enabled. ユーザーがライブ更新を OFF に
    // している場合 (#854) は WebSocket を張らず、インジケータを disabled にする。
    // 初期判定は read で行う。watch すると、トグル切替が build() 全体（REST 再
    // フェッチ・スクロール位置リセット・_pendingPosts.clear 等）を誘発し、可視の
    // スクロールジャンプを起こす (#904)。切替の張り/解除は build() 側の listen。
    if (adapter is StreamSupport && ref.read(streamingEnabledProvider)) {
      _startStreaming(adapter as StreamSupport, type);
    }

    fetchSw?.stop();

    // item3 (#716): isCat enrich をクリティカルパスから外す。初回描画は未 enrich の
    // posts で即返し、moroheiya /account/is_cat による猫フラグ補完は描画後に
    // バックグラウンドで適用する（キャッシュ駆動で冪等・装飾のみ）。Misskey は
    // adapter 取得時点で isCat 確定済みのため、影響を受けるのは Mastodon×moroheiya
    // のみ。first paint 計測はこの即返し時点を起点に記録する（enrich は除外）。
    if (measureHomePaint) {
      _homeFirstPaintReported = true;
    }

    // ギャップ補完 (#781) の since_id 起点。初回 REST スナップショットの先頭を
    // 記録しておき、WS が live になった時点でこの id より新しい投稿を取り直す。
    _newestKnownId = allVisible.firstOrNull?.id;

    unawaited(
      _deferIsCatEnrich(
        initialPosts: allVisible,
        contextKey: contextKey,
        measureHomePaint: measureHomePaint,
        fetchMs: fetchSw?.elapsedMilliseconds ?? 0,
        sinceLaunchAtPaintMs: measureHomePaint
            ? appLaunchStopwatch.elapsedMilliseconds
            : 0,
        fetches: fetches,
        // 既読位置復元 (#715) の ON/OFF で起動の体感は大きく変わる（ON は
        // first paint 後に getMarkers 往復＋古い位置へ着地）。混在させると平均が
        // 無意味になるため、計測を設定値で層別できるようタグ付けする。マーカー
        // 復元そのものの所要は home_screen 側の startup.marker_restore で測る。
        restoreReadPosition: ref.read(restoreReadPositionProvider),
      ),
    );

    // 次の起動で先出しできるよう、ホーム TL の初回ページを控える (#890)。
    // 書き込み失敗は握り潰される（キャッシュは無くても動く）。
    if (type == TimelineType.home && contextKey != null && allRaw.isNotEmpty) {
      unawaited(TimelineCache.save(contextKey, allRaw, now: DateTime.now()));
    }

    final fresh = TimelineState(
      posts: allVisible,
      hasMore: hasMore,
      pageCapHit: pageCapHit,
      contextKey: contextKey,
      // 現在値を反映（stream 接続が即 live になっても取りこぼさない, #714）。
      streamConnectionState: _streamConnectionState,
    );

    // キャッシュ先出しの裏で走った場合は、自分で state を差し替える。文脈が
    // 変わっている（アカウント/タブ切替で build() がやり直された）なら捨てる。
    if (publishToState &&
        !_isStale(generation, contextKey, publishToState: true)) {
      state = AsyncData(fresh);
    }
    return fresh;
  }

  /// この取得の結果が既に用済みか。破棄済み・再計算で世代が進んだ・表示中の文脈が
  /// 変わった、のいずれか (#890)。
  ///
  /// [publishToState] が false のとき（`build()` の返り値として await されている
  /// 途中）は state がまだ `AsyncLoading` なので、表示中の contextKey とは比べない。
  /// 比べると初回取得が常に stale 判定になる。
  bool _isStale(
    int generation,
    String? contextKey, {
    required bool publishToState,
  }) {
    if (_disposed) return true;
    if (generation != _buildGeneration) return true;
    if (publishToState && state.valueOrNull?.contextKey != contextKey) {
      return true;
    }
    return false;
  }

  /// キャッシュ先出しの裏で走る初回取得 (#890)。**失敗を握り潰さないための層**。
  ///
  /// [_loadInitial] は `build()` の返り値として await されるときだけ Riverpod が
  /// 例外を [AsyncError] に変換してくれる。キャッシュ先出し経路では `unawaited` で
  /// 走らせるため、そのままだと取得に失敗しても
  ///
  /// - 画面には**最大 24 時間前のキャッシュが「生きた TL」として出続ける**
  ///   （エラー表示も再試行導線も出ない）
  /// - `_startStreaming` は取得の後にあるため**ライブ更新も張られない**
  /// - 例外は未処理の非同期エラーとしてゾーンへ落ち、Sentry に unhandled で載る
  ///
  /// という三重の劣化が起きる。**キャッシュがある方がエラー処理が弱くなる**のは
  /// 筋が通らないので、ここで捕まえてキャッシュ無し経路と同じ [AsyncError] に
  /// 揃える（再試行はホーム画面の error ブランチが出す）。
  Future<void> _loadInitialInBackground({
    required DecentralizedBackendAdapter adapter,
    required TimelineType type,
    required String? contextKey,
    required bool hideLivecure,
    required int generation,
  }) async {
    // 「キャッシュを描いてから実物に置き換わるまで」を測る (#890)。
    //
    // この経路が定常状態になると `app.startup.home_timeline` は from_cache=true
    // ばかりになり、**サーバー応答時間 (fetch_ms) を持つコホートが「キャッシュを
    // 使えなかった起動」（初回・24h 超・文脈違い）だけに縮む**。定常状態を代表
    // しない層しか残らないので、REST が遅くなっても起動計測は速くなったように
    // しか見えない。置き換えまでの所要をここで別 transaction として残し、
    // #890 の効果と REST の実勢を切り分けられるようにする。
    final swapSw = Stopwatch()..start();
    try {
      final fresh = await _loadInitial(
        adapter: adapter,
        type: type,
        contextKey: contextKey,
        hideLivecure: hideLivecure,
        // 初回描画はキャッシュ側で計測済み。二重に report しない。
        measureHomePaint: false,
        publishToState: true,
        generation: generation,
      );
      swapSw.stop();
      // 途中で捨てられた回（破棄 / 世代進み / 文脈変更）は所要の意味が変わるので
      // 記録しない。_isStale と同じ判定を使う。
      if (_isStale(generation, contextKey, publishToState: true)) return;
      // transaction の duration そのものが所要（取得 + enrich + 差し替え）。
      // 別 measurement には積まない（同じ値の二重持ちになる）。
      recordStartupPhase(
        'app.startup.home_timeline_swap',
        durationMs: swapSw.elapsedMilliseconds,
        data: {'posts': fresh.posts.length},
      );
    } catch (e, st) {
      // 破棄済み / 世代が進んだ / 文脈が変わった場合は、もう自分の結果に用は無い。
      if (_disposed) return;
      if (generation != _buildGeneration) return;
      if (state.valueOrNull?.contextKey != contextKey) return;
      // 例外文字列にはホストや生データ断片が載りうるため詰め替えてから送る
      // (#586 / #743)。unhandled ではなく「意図して捕捉した失敗」として残す。
      final scrubbed = scrubException(e);
      // タグ無しだと汎用の DioException に紛れて、ホーム TL の初回取得失敗として
      // 数えられない。なおこの捕捉は**キャッシュ先出し経路にしか無い**（キャッシュ
      // 無しの起動は build() が投げたものを Riverpod が AsyncError にするだけで
      // Sentry へは出ない）ので、この tag の件数は「キャッシュがあった起動の失敗」
      // に偏る。母数として読むときは from_cache=true の起動数と突き合わせること。
      unawaited(
        Sentry.captureException(
          scrubbed,
          stackTrace: st,
          withScope: (scope) => scope.setTag('phase', 'startup_timeline'),
        ),
      );
      state = AsyncError(scrubbed, st);
    }
  }

  /// 起動直後の 1 回だけ、前回のホーム TL をディスクから読んで先出しする (#890)。
  ///
  /// 使えない条件（ホーム以外・2 回目以降・アダプタ非対応・期限切れ・文脈違い・
  /// 復号できる投稿が 0 件）では null を返し、呼び出し側は従来どおり REST の
  /// 完了を待つ。
  Future<TimelineState?> _loadStartupCache({
    required DecentralizedBackendAdapter adapter,
    required TimelineType type,
    required String? contextKey,
    required bool hideLivecure,
    required bool measureHomePaint,
  }) async {
    if (type != TimelineType.home) return null;
    if (contextKey == null) return null;
    if (_startupCacheServed) return null;
    if (adapter is! TimelineCacheSupport) return null;
    _startupCacheServed = true;

    final sw = Stopwatch()..start();
    final raw = await TimelineCache.load(contextKey, now: DateTime.now());
    if (raw == null || raw.isEmpty) return null;

    final List<Post> posts;
    try {
      posts = (adapter as TimelineCacheSupport)
          .decodeCachedPosts(raw)
          // 保存時と設定が変わっていることがあるので、フィルタは読み出し側でも
          // かけ直す（直後に届く REST の結果でどのみち正される）。
          .where((p) => p.filterAction != FilterAction.hide)
          .where((p) => !hideLivecure || !_hasLivecureTag(p))
          .toList();
    } catch (e) {
      // 例外をそのまま出さない理由は timeline_cache.dart の save 側コメント参照
      // （release では debugPrint が Sentry breadcrumb になる）。
      debugPrint(
        'capsicum: timeline cache decode failed: ${scrubException(e)}',
      );
      return null;
    }
    if (posts.isEmpty) return null;
    sw.stop();

    // ギャップ補完 (#781) の起点はキャッシュの先頭にはしない。裏で走る REST が
    // 直後に _newestKnownId を正しく張り直すため、ここでは触らない。

    if (measureHomePaint) {
      _homeFirstPaintReported = true;
      _reportHomeFirstPaint(
        sinceLaunchMs: appLaunchStopwatch.elapsedMilliseconds,
        fetchMs: 0,
        enrichMs: 0,
        posts: posts.length,
        fetches: 0,
        restoreReadPosition: ref.read(restoreReadPositionProvider),
        fromCache: true,
        cacheReadMs: sw.elapsedMilliseconds,
      );
    }

    return TimelineState(
      posts: posts,
      contextKey: contextKey,
      streamConnectionState: _streamConnectionState,
      fromCache: true,
    );
  }

  /// item3 (#716): 初回ページの isCat enrich を描画後に遅延適用する。
  ///
  /// build() は未 enrich の posts で即返しているため、ここで moroheiya
  /// `/account/is_cat` を引いて猫フラグキャッシュを温め、その結果を **最新の**
  /// state（描画後に streaming が prepend している可能性がある）へ再適用する。
  /// enrich は装飾のみなので、失敗・dispose・文脈切替時は黙って破棄してよい。
  Future<void> _deferIsCatEnrich({
    required List<Post> initialPosts,
    required String? contextKey,
    required bool measureHomePaint,
    required int fetchMs,
    required int sinceLaunchAtPaintMs,
    required int fetches,
    required bool restoreReadPosition,
  }) async {
    final enrichSw = Stopwatch()..start();
    try {
      // キャッシュ温め目的。返り値は使わず、最新 state へ _applyIsCat で再適用する。
      await _enrichIsCat(initialPosts);
    } catch (_) {
      // enrich は装飾。失敗しても初回描画は成立しているので握り潰す。
    }
    enrichSw.stop();

    try {
      final latest = state.valueOrNull;
      if (latest != null && latest.contextKey == contextKey) {
        final reapplied = latest.posts.map(_applyIsCat).toList();
        if (_hasIsCatChange(reapplied, latest.posts)) {
          state = AsyncData(latest.copyWith(posts: reapplied));
        }
      }
    } catch (_) {
      // dispose / 文脈切替の最中。装飾更新なので破棄してよい。
    }

    if (measureHomePaint) {
      _reportHomeFirstPaint(
        sinceLaunchMs: sinceLaunchAtPaintMs,
        fetchMs: fetchMs,
        enrichMs: enrichSw.elapsedMilliseconds,
        posts: initialPosts.length,
        fetches: fetches,
        restoreReadPosition: restoreReadPosition,
      );
    }
  }

  /// 2 つの posts リストで isCat 再適用による差し替えが起きたか（要素の同一性で判定）。
  bool _hasIsCatChange(List<Post> a, List<Post> b) {
    if (a.length != b.length) return true;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return true;
    }
    return false;
  }

  /// ホーム TL の初回描画到達を計測ログ / Sentry transaction に残す (#716)。
  /// since_launch_ms（起動→初回描画・enrich 除外）と fetch_ms（サーバー応答）で
  /// 体感の主因を切り分ける。enrich_ms は item3 で描画後に遅延化した isCat 補完の
  /// 所要で、もはやクリティカルパスには載らない参考値。
  void _reportHomeFirstPaint({
    required int sinceLaunchMs,
    required int fetchMs,
    required int enrichMs,
    required int posts,
    required int fetches,
    required bool restoreReadPosition,
    bool fromCache = false,
    int cacheReadMs = 0,
  }) {
    // since_launch_ms は初回描画（未 enrich の即返し）時点で確定させた値。
    // item3 適用後は enrich がクリティカルパスから外れたため、この値には
    // enrich_ms を含まない。enrich_ms は描画後の遅延 enrich の所要を別途記録する。
    debugPrint(
      'capsicum: startup: home timeline first paint in '
      '${sinceLaunchMs}ms since launch '
      '(fetch=${fetchMs}ms deferred_enrich=${enrichMs}ms posts=$posts '
      'fetches=$fetches restoreReadPosition=$restoreReadPosition '
      'fromCache=$fromCache cacheRead=${cacheReadMs}ms)',
    );
    // 起動計測 (#716): transaction duration = since_launch_ms（起動→初回描画）。
    // fetch_ms（サーバー）/ enrich_ms（描画後に遅延した isCat 補完）は measurement、
    // 既読位置復元の ON/OFF は tag で層別する。
    recordStartupPhase(
      'app.startup.home_timeline',
      durationMs: sinceLaunchMs,
      measurementsMs: {
        // キャッシュ先出しの回はサーバーを待っていないので、fetch / enrich は
        // 「0ms」ではなく**欠測**にする。0 を混ぜると fetch_ms の平均・p95 が
        // 実測していない値で薄まり、from_cache で絞らない限り読めなくなる (#890)。
        if (!fromCache) 'fetch_ms': fetchMs,
        if (!fromCache) 'enrich_ms': enrichMs,
        // 先出し時のディスク読み出し。サーバー応答と桁が違うことを確認するため
        // 別枠で持つ (#890)。
        if (fromCache) 'cache_read_ms': cacheReadMs,
      },
      tags: {
        'restore_read_position': '$restoreReadPosition',
        // 起動時キャッシュから描いたか (#890)。before/after はこのタグで分ける。
        'from_cache': '$fromCache',
      },
      data: {'posts': posts, 'fetches': fetches},
    );
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
  // 切断 (onDone) の closeCode 観測用バケット (#788)。性質が違うので
  // connect/parse/listen とは独立に持つ。
  DateTime? _lastDisconnectCapture;
  static const _captureThrottle = Duration(seconds: 60);

  /// 接続ライフサイクルを notifier フィールドと（データがあれば）state に
  /// 反映する。build() 中に onConnectionState が取りこぼさないための常時記録と
  /// 同じ理由で、まずフィールドへ、次に state があれば更新する。
  void _setStreamConnectionState(StreamConnectionState connState) {
    _streamConnectionState = connState;
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(streamConnectionState: connState));
  }

  /// ライブ更新トグルを OFF にしたときの接続解除 (#904)。build() を再走させず
  /// WebSocket の購読だけを止め、インジケータを disabled にする。
  void _stopStreaming(StreamSupport adapter) {
    _streamSubscription?.cancel();
    _streamSubscription = null;
    adapter.disposeStream();
    _setStreamConnectionState(StreamConnectionState.disabled);
  }

  void _startStreaming(StreamSupport adapter, TimelineType type) {
    _streamSubscription?.cancel();
    // 切断系イベント (disconnected / reconnect_exhausted) を Sentry 上で
    // サーバー別に切り分けられるよう host を控える (#826)。挙動は host で分岐
    // しない (per-server workaround は入れない)。付与するのは観測タグのみで、
    // push.host と同型に host のみ載せ生 URL / トークンは載せない。
    final host = ref.read(currentAccountProvider)?.key.host;
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
            if (host != null) scope.setTag('timeline.stream.host', host);
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
      // 接続ライフサイクルを state に反映し、常時インジケータへ流す (#714)。
      // build() 中（state が AsyncLoading で valueOrNull が null）に発火しても
      // 取りこぼさないよう、まず notifier フィールドへ常時記録する。state に
      // データがあればそれも更新する。
      onConnectionState: (connState) {
        _streamConnectionState = connState;
        // 切断を検知したら回数・時刻を記録する (#782)。source 側で同一状態は
        // dedup されるため、disconnected の発火 = 1 回の接続失敗サイクル。
        if (connState == StreamConnectionState.disconnected) {
          _reconnectCount++;
          _lastDisconnectedAt = DateTime.now();
        }
        // WS が live になるたび（初回接続・各再接続）、接続が確立していなかった
        // 窓に流れた投稿を since_id で取り直す (#781)。これが無いと「初回 REST →
        // WS live までの窓」「切断〜再接続の窓」に入った投稿が永久に欠落する
        // （実況中の取りこぼし報告の根因）。装飾でなく本機能なので最新 state へ
        // マージする。
        if (connState == StreamConnectionState.live) {
          unawaited(_catchUpSinceTop());
        }
        final current = state.valueOrNull;
        if (current == null) return;
        state = AsyncData(
          current.copyWith(
            streamConnectionState: connState,
            reconnectCount: _reconnectCount,
            lastDisconnectedAt: _lastDisconnectedAt,
            // #784 で give-up せず再試行を続けるため、live 復帰時に exhausted
            // フラグをクリアする。これが無いと一度 exhausted を踏むと復帰後も
            // 「停止」表示が残り、次の枯渇で false→true の SnackBar も出なく
            // なる (Codex #780)。live 以外では現状維持（null）。
            streamReconnectExhausted: connState == StreamConnectionState.live
                ? false
                : null,
          ),
        );
      },
      // 「どんな切れ方をしているか」を本番で観測する (#788)。現象すら未把握な
      // ので原因対処はせず計器のみ。実測 (2026-07-11) では close_code 1002
      // (protocol error) が支配的で、1001 (going away) / 1000 (正常) /
      // 1006 (異常) が続く。host タグで発生サーバーを切り分ける (#826) が、
      // 挙動は host で分岐しない (per-server workaround は入れない)。closeReason
      // はサーバー任意文字列を持ちうるため内容は載せず、有無のみ。throttle で
      // 切断連発の spam を抑える。
      onDisconnect: (closeCode, closeReason) {
        final now = DateTime.now();
        if (_lastDisconnectCapture != null &&
            now.difference(_lastDisconnectCapture!) < _captureThrottle) {
          return;
        }
        _lastDisconnectCapture = now;
        final code = closeCode?.toString() ?? 'none';
        Sentry.captureMessage(
          'timeline.stream.disconnected',
          level: SentryLevel.info,
          withScope: (scope) {
            scope.setTag('timeline.stream', 'disconnected');
            if (host != null) scope.setTag('timeline.stream.host', host);
            scope.setTag('timeline.stream.close_code', code);
            scope.setTag(
              'timeline.stream.has_reason',
              (closeReason != null && closeReason.isNotEmpty).toString(),
            );
            scope.fingerprint = ['timeline.stream.disconnected', code];
          },
        );
      },
    );
    _streamSubscription = stream.listen(
      (newPost) => _ingestLivePosts([newPost]),
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

  /// streaming 受信とギャップ補完 (#781) の共通取り込み口。
  ///
  /// フィルタ (hide / hideLivecure) と重複排除 (表示中 + pending + バッチ内) を
  /// 単発受信・バッチ補完で同一に適用する。[newPosts] は **新しい順**（先頭が
  /// 最新）で渡す。near-top なら先頭へブロック prepend、スクロール中なら
  /// streaming と同じく pending キューへ積んでジャンプを防ぐ。
  ///
  /// 戻り値は実際に取り込んだ（フィルタ・重複排除を通過した）件数。ギャップ
  /// 補完の実効を観測する (#784) のに使う。
  int _ingestLivePosts(List<Post> newPosts) {
    if (newPosts.isEmpty) return 0;
    final current = state.valueOrNull;
    if (current == null) return 0;
    final hideLivecure = ref.read(hideLivecureProvider);
    final existingIds = {for (final p in current.posts) p.id};
    final pendingIds = {for (final p in _pendingPosts) p.id};
    final accepted = <Post>[];
    final acceptedIds = <String>{};
    for (final post in newPosts) {
      if (post.filterAction == FilterAction.hide) continue;
      if (hideLivecure && _hasLivecureTag(post)) continue;
      if (existingIds.contains(post.id) || pendingIds.contains(post.id)) {
        continue;
      }
      if (!acceptedIds.add(post.id)) continue; // バッチ内重複
      accepted.add(post);
    }
    if (accepted.isEmpty) return 0;

    if (_isNearTop) {
      // accepted を現在リストへマージし id 降順を保つ。単発 streaming（常に最新）
      // では実質 prepend だが、ギャップ補完バッチが streaming の prepend と
      // 競合（fetch 待ちの間に新しい投稿が先に載る）しても順序が崩れないよう、
      // ブロック prepend ではなくマージ＋ソートにする (#781)。タイムラインは
      // 元々 id 降順なのでソートはほぼ冪等で、件数も数百どまり。
      final merged = [...accepted, ...current.posts]
        ..sort((a, b) => comparePostIdDesc(a.id, b.id));
      _newestKnownId = merged.first.id;
      state = AsyncData(current.copyWith(posts: merged));
    } else {
      // User is scrolling — queue to avoid jumping. flushPending で id 降順に
      // 整列して取り込むため、ここでは順不同で積んでよい。
      _pendingPosts.addAll(accepted);
      _newestKnownId = _maxPostId(_newestKnownId, accepted.first.id);
      state = AsyncData(current.copyWith(pendingCount: _pendingPosts.length));
    }
    return accepted.length;
  }

  /// 2 つの id のうち新しい（降順で前に来る）方を返す (#781)。
  String _maxPostId(String? a, String b) {
    if (a == null) return b;
    return comparePostIdDesc(a, b) <= 0 ? a : b;
  }

  /// WS が live になった時点で、未接続の窓に流れて取りこぼした投稿を
  /// `since_id` で取り直してマージする (#781)。
  ///
  /// 初回 REST スナップショット〜WS live、および各再接続の切断窓に作られた
  /// 投稿はどの経路でも届かず永久欠落するため、live 遷移ごとにここで埋める。
  /// [_newestKnownId] を起点に、ギャップが 1 ページを超える場合は max_id で
  /// 下方向にページングして [kMaxVisibilityPageFetches] ページまで遡る。
  ///
  /// 初期可視リストが空（新規/空 TL・全件フィルタ・page-cap）で [_newestKnownId]
  /// が null のときも、REST→live 窓に作られた投稿を取りこぼさないよう最新ページ
  /// 1 枚だけ取得してシードする (Codex #783)。
  Future<void> _catchUpSinceTop() async {
    if (_catchUpInProgress) return;
    final since = _newestKnownId;
    // await 中にアカウント/種別が切り替わると build() が rerun して notifier が
    // 新文脈に作り直されるが、この future はキャンセルされない。旧文脈で取得した
    // 投稿を新文脈へマージしないよう、開始時の contextKey を捕捉し ingest 直前に
    // 照合する (#758 / _deferIsCatEnrich と同型・Codex #783)。
    final capturedContextKey = state.valueOrNull?.contextKey;
    _catchUpInProgress = true;
    try {
      final adapter = ref.read(currentAdapterProvider);
      final type = ref.read(selectedTimelineTypeProvider);
      if (adapter == null) return;

      final gap = await collectCatchUpGap(
        since: since,
        pageSize: _pageSize,
        maxFetches: kMaxVisibilityPageFetches,
        fetch: (maxId) async {
          final response = await adapter.getTimeline(
            type,
            query: TimelineQuery(maxId: maxId, limit: _pageSize),
          );
          return (
            posts: response.posts,
            rawCount: response.rawCount,
            rawLastId: response.rawLastId,
          );
        },
      );

      if (gap.isEmpty) return;
      // await 中に文脈が変わっていたら破棄（旧文脈の投稿の混入・_newestKnownId
      // 汚染を防ぐ）。_ingestLivePosts は同期なので照合後の混入はない。
      if (state.valueOrNull?.contextKey != capturedContextKey) return;
      // getTimeline は新しい順・ページも新しい方から取得するため gap は新しい順。
      // 取り込み時に再度 state を読み、最新 state へマージする。
      final recovered = _ingestLivePosts(gap);
      // 再接続のたびに何件を補完できたかを観測する (#784 item 3)。resilience
      // (#784) × catch-up (#781) の実効を本番で追跡するための軽量シグナル。
      // PII を載せない（件数のみ）。
      if (recovered > 0) {
        Sentry.addBreadcrumb(
          Breadcrumb(
            message: 'timeline.stream.catchup',
            category: 'timeline.stream',
            level: SentryLevel.info,
            data: {'recovered': recovered, 'fetched': gap.length},
          ),
        );
      }
    } catch (_) {
      // 補完の失敗で本筋を止めない。次の live 遷移 / pull-to-refresh で再試行。
    } finally {
      _catchUpInProgress = false;
    }
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
    // pending は順不同で積まれうる (#781: streaming 単発とギャップ補完バッチが
    // 混在)。id でデデュープしつつ降順に整列して取り込む。
    final seen = <String>{};
    final merged = <Post>[];
    for (final post in [..._pendingPosts, ...current.posts]) {
      if (seen.add(post.id)) merged.add(post);
    }
    merged.sort((a, b) => comparePostIdDesc(a.id, b.id));
    _pendingPosts.clear();
    if (merged.isNotEmpty) _newestKnownId = merged.first.id;
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
    state = AsyncData(
      current.copyWith(
        posts: posts,
        pendingCount: _dropPending((p) => p.id == id),
      ),
    );
  }

  /// 未表示バッファ [_pendingPosts] から条件に合う投稿を落とし、新しい
  /// `pendingCount` を返す。
  ///
  /// TL 上部から離れている間、streaming の新着は表示中の一覧ではなく
  /// [_pendingPosts] に溜まる（「新着 N 件」で開くまで出さない、#296）。
  /// 一覧からだけ消してここを掃除しないと、**削除済み投稿やブロックした相手の
  /// 投稿が「新着 N 件」を開いた瞬間に現れる**。ブロックは安全のための操作なので
  /// 「見えているどの TL からも消える」保証 (#887) を穴のない形にする。
  int _dropPending(bool Function(Post) matches) {
    _pendingPosts.removeWhere(matches);
    return _pendingPosts.length;
  }

  /// 自分の投稿を即座に**現在アクティブな TL** の先頭へ楽観的挿入する (#717)。
  /// 投稿成功直後に呼ぶ。この provider は [selectedTimelineTypeProvider] を
  /// watch するため、挿入先は home 固定ではなく今表示中の TL（home / local /
  /// social / federated）になる。
  ///
  /// 旧実装は投稿後に `invalidate(timelineProvider)` で REST 全再取得していたが、
  /// 取得タイミング次第（連合/負荷時のサーバー伝播レース）で自分の投稿がまだ
  /// サーバーに index されておらず「投稿しても出ない」ことがあった。楽観挿入なら
  /// REST 再取得・ストリーミング状態に依存せず必ず即時に出る。後から streaming /
  /// REST で同じ id が来ても二重表示しないよう、既存なら何もしない。
  ///
  /// ストリーミング受信時 ([_streamSubscription] の listener) と同じフィルタを
  /// 適用する: フィルタ hide / hideLivecure 中の #実況（#433 の SnackBar 告知に
  /// 委ねる）は挿入しない。加えて、**表示中の TL に実際に載る投稿だけ**を挿入する
  /// ([_ownPostVisibleInTimeline]、#814)。載らない投稿を差し込むとリフレッシュで
  /// 消える幻の投稿になるため。
  void insertOwnPost(Post post) {
    final current = state.valueOrNull;
    // build 中・未構築なら何もしない（後続の REST / streaming が拾う）。
    if (current == null) return;
    // 表示中の TL 種別にこの投稿が実際に載るか（種別 × 公開範囲）で弾く (#814)。
    final type = ref.read(selectedTimelineTypeProvider);
    if (!ownPostAppearsInTimeline(type, post)) return;
    if (post.filterAction == FilterAction.hide) return;
    final hideLivecure = ref.read(hideLivecureProvider);
    if (hideLivecure && _hasLivecureTag(post)) return;
    if (current.posts.any((p) => p.id == post.id)) return;
    if (_pendingPosts.any((p) => p.id == post.id)) return;
    // streaming は `!_isNearTop` のとき _pendingPosts にキューしてスクロール
    // ジャンプを防ぐが、自分の投稿は「投稿したのに出ない」を避けるため位置に
    // 関わらず即座に先頭へ出す（意図的に _isNearTop を見ない）。
    // 自分の投稿は最新なので since_id 起点 (#781) も前進させる。
    _newestKnownId = post.id;
    state = AsyncData(current.copyWith(posts: [post, ...current.posts]));
  }

  /// Remove all posts by a user (e.g. after block/mute).
  void removePostsByUser(String userId) {
    final current = state.valueOrNull;
    if (current == null) return;
    bool byUser(Post p) =>
        p.author.id == userId || p.reblog?.author.id == userId;
    final posts = current.posts.where((p) => !byUser(p)).toList();
    state = AsyncData(
      current.copyWith(posts: posts, pendingCount: _dropPending(byUser)),
    );
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

        final pageCapHit =
            fetches >= kMaxVisibilityPageFetches &&
            allVisible.isEmpty &&
            hasMore;
        if (pageCapHit) {
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
            pageCapHit: pageCapHit,
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

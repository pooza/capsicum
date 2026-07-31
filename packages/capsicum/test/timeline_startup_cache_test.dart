import 'dart:async';
import 'dart:io';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum/src/service/timeline_cache.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #890 item2: ホーム TL の起動時キャッシュ。
///
/// 「前回の一覧を先に描き、REST は裏で追いついて置き換える」経路を、実際の
/// [timelineProvider] を通して確認する。ここが壊れると起動直後に古い一覧が
/// 残り続ける / そもそも先出しされない、のどちらかになる。
class _FakeAdapter extends Mock
    implements DecentralizedBackendAdapter, TimelineCacheSupport {
  _FakeAdapter({required this.fresh, this.fetchGate, this.failFetch = false});

  /// getTimeline が返す「サーバー側の」投稿。
  final List<Post> fresh;

  /// 非 null のとき、getTimeline はこの gate が完了するまで待つ。
  final Future<void>? fetchGate;

  /// true のとき getTimeline は投げる（オフライン起動・5xx 相当）。
  final bool failFetch;

  int fetchCount = 0;

  @override
  AdapterCapabilities get capabilities => _FakeCapabilities();

  @override
  Future<TimelineResponse> getTimeline(
    TimelineType type, {
    TimelineQuery? query,
  }) async {
    fetchCount++;
    if (fetchGate != null) await fetchGate;
    if (failFetch) throw Exception('network down');
    if (query?.maxId != null) {
      return const TimelineResponse(posts: [], rawCount: 0);
    }
    return TimelineResponse(
      posts: fresh,
      rawCount: fresh.length,
      rawLastId: fresh.isNotEmpty ? fresh.last.id : null,
      rawJson: [
        for (final p in fresh) {'id': p.id, 'content': p.content},
      ],
    );
  }

  @override
  List<Post> decodeCachedPosts(List<Map<String, dynamic>> raw) => [
    for (final e in raw) _post('${e['id']}', content: '${e['content']}'),
  ];
}

class _FakeCapabilities extends Mock implements AdapterCapabilities {
  @override
  Set<TimelineType> get supportedTimelines => {TimelineType.home};
}

Post _post(String id, {String content = 'body'}) => Post(
  id: id,
  postedAt: DateTime.utc(2026, 7, 31),
  author: const User(id: 'u1', username: 'me'),
  content: content,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('capsicum_startup_cache');
    TimelineCache.directoryOverride = dir.path;
    TimelineNotifier.resetStartupStateForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
  });

  tearDown(() {
    TimelineCache.directoryOverride = null;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  ProviderContainer makeContainer(_FakeAdapter adapter) {
    final account = Account(
      key: const AccountKey(
        type: BackendType.mastodon,
        host: 'example.test',
        username: 'me',
      ),
      adapter: adapter,
      user: const User(id: 'u1', username: 'me'),
      userSecret: const UserSecret(accessToken: 'token'),
    );
    final container = ProviderContainer(
      overrides: [currentAccountProvider.overrideWith((ref) => account)],
    );
    // autoDispose なので、購読を張らないと read 直後に捨てられて裏の取得結果を
    // 受け取れない（実アプリでは HomeScreen が watch し続けている状態に相当）。
    container.listen(timelineProvider, (_, _) {}, fireImmediately: true);
    return container;
  }

  String contextKeyFor() => timelineContextKey(
    const AccountKey(
      type: BackendType.mastodon,
      host: 'example.test',
      username: 'me',
    ),
    'tl:home',
  )!;

  test('キャッシュがあれば REST を待たずにそれを先に返す', () async {
    await TimelineCache.save(contextKeyFor(), [
      {'id': 'cached1', 'content': '前回の投稿'},
    ], now: DateTime.now());

    // REST は解放するまで返らない。先出しが REST 待ちでないことを保証する。
    final gate = Completer<void>();
    final adapter = _FakeAdapter(
      fresh: [_post('new1')],
      fetchGate: gate.future,
    );
    final container = makeContainer(adapter);
    addTearDown(container.dispose);

    final first = await container.read(timelineProvider.future);

    expect(first.fromCache, isTrue);
    expect(first.posts.map((p) => p.id), ['cached1']);

    // 解放すると、裏で走っていた取得結果へ置き換わる。
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final after = container.read(timelineProvider).value!;
    expect(after.fromCache, isFalse);
    expect(after.posts.map((p) => p.id), ['new1']);
  });

  /// リリース前レビュー (v1.53) で 5 観点中 4 つから独立に挙がった 🔴。
  ///
  /// 先出しの裏で走る取得は `unawaited` なので、失敗しても build() の返り値には
  /// ならず AsyncError に変換されない。放置すると「最大 24 時間前のキャッシュが
  /// 生きた TL に見えたまま、エラー表示も再試行導線も streaming も無い」状態で
  /// 固まり、例外だけが未処理として Sentry に載る。
  test('先出しの裏で取得が失敗したら、黙って古い一覧を出し続けずエラーにする', () async {
    await TimelineCache.save(contextKeyFor(), [
      {'id': 'cached1', 'content': '前回の投稿'},
    ], now: DateTime.now());

    final adapter = _FakeAdapter(fresh: const [], failFetch: true);
    final container = makeContainer(adapter);
    addTearDown(container.dispose);

    // 先出し自体は従来どおり成功する。
    final first = await container.read(timelineProvider.future);
    expect(first.fromCache, isTrue);
    expect(first.posts.map((p) => p.id), ['cached1']);

    // 裏の取得が失敗したら、キャッシュ無し経路と同じくエラーへ倒す
    // （ホーム画面の error ブランチが再試行を出す）。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(timelineProvider).hasError,
      isTrue,
      reason: '古いキャッシュを「生きた TL」として出し続けない',
    );
  });

  test('キャッシュが無ければ従来どおり REST の結果を返す', () async {
    final adapter = _FakeAdapter(fresh: [_post('new1')]);
    final container = makeContainer(adapter);
    addTearDown(container.dispose);

    final state = await container.read(timelineProvider.future);

    expect(state.fromCache, isFalse);
    expect(state.posts.map((p) => p.id), ['new1']);
  });

  test('取得に成功したら次回のためにキャッシュを書く', () async {
    final adapter = _FakeAdapter(fresh: [_post('new1'), _post('new2')]);
    final container = makeContainer(adapter);
    addTearDown(container.dispose);

    await container.read(timelineProvider.future);
    // 保存は unawaited なので 1 tick 待つ。
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final saved = await TimelineCache.load(
      contextKeyFor(),
      now: DateTime.now(),
    );
    expect(saved?.map((e) => e['id']), ['new1', 'new2']);
  });

  test('先出しは 1 プロセス 1 回だけ（セッション中の切替で古い一覧を出さない）', () async {
    await TimelineCache.save(contextKeyFor(), [
      {'id': 'cached1', 'content': '前回の投稿'},
    ], now: DateTime.now());

    final adapter = _FakeAdapter(fresh: [_post('new1')]);
    final container = makeContainer(adapter);
    addTearDown(container.dispose);

    final first = await container.read(timelineProvider.future);
    expect(first.fromCache, isTrue);

    container.invalidate(timelineProvider);
    final second = await container.read(timelineProvider.future);
    expect(second.fromCache, isFalse);
  });
}

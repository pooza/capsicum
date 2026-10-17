import 'dart:async';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/list_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1292: 実況を隠すモードで、全部消えたページが続いても続き読みが先へ進む。
///
/// ⚠⚠ 以前は続き読みの起点を「表示中の最後の投稿」にしていたので、引いた
/// ページが全部消えると起点が動かず、同じページを引き直し続けて止まっていた
/// （放送中のホームで実際に踏んだ）。ハッシュタグは v2.2 で直してある
/// （`hashtag_load_more_cursor_test.dart`）。
class _FakeCapabilities extends Mock implements AdapterCapabilities {
  @override
  Set<TimelineType> get supportedTimelines => {TimelineType.home};
}

/// 新しい順に並んだ投稿を、`maxId` より古い側から 1 ページずつ返す。
class _PagedAdapter extends Mock
    implements DecentralizedBackendAdapter, ListSupport {
  _PagedAdapter(this.all);

  final List<Post> all;
  final List<String?> requestedMaxIds = [];

  /// 立っている間、続き読み（`maxId` あり）の取得をここで待たせる。
  Completer<void>? gate;

  /// この `maxId` での取得を 1 回だけ失敗させる（#1293）。
  String? failOnceAt;

  @override
  AdapterCapabilities get capabilities => _FakeCapabilities();

  List<Post> _page(TimelineQuery? query) {
    final maxId = query?.maxId;
    requestedMaxIds.add(maxId);
    final start = maxId == null ? 0 : all.indexWhere((p) => p.id == maxId) + 1;
    return all.skip(start).take(query?.limit ?? 20).toList();
  }

  @override
  Future<TimelineResponse> getTimeline(
    TimelineType type, {
    TimelineQuery? query,
  }) async {
    final page = _page(query);
    final g = gate;
    if (g != null && query?.maxId != null) await g.future;
    if (failOnceAt != null && query?.maxId == failOnceAt) {
      failOnceAt = null;
      throw Exception('network');
    }
    return TimelineResponse(
      posts: page,
      rawCount: page.length,
      rawLastId: page.lastOrNull?.id,
    );
  }

  @override
  Future<List<Post>> getListTimeline(
    String listId, {
    TimelineQuery? query,
  }) async {
    final page = _page(query);
    final g = gate;
    if (g != null && query?.maxId != null) await g.future;
    return page;
  }
}

const _meKey = AccountKey(
  type: BackendType.mastodon,
  host: 'example.test',
  username: 'me',
);

Post _post(int n, {required bool livecure}) => Post(
  // 新しいほど大きい id（並びは降順で渡す）。
  id: n.toString().padLeft(4, '0'),
  postedAt: DateTime.utc(2026, 10, 15),
  author: const User(id: 'u1', username: 'u1'),
  content: livecure ? 'わんぷり #実況' : 'body',
);

Future<ProviderContainer> _container(_PagedAdapter adapter) async {
  final container = ProviderContainer(
    overrides: [
      currentAccountProvider.overrideWith(
        (ref) => Account(
          key: _meKey,
          adapter: adapter,
          user: const User(id: 'me', username: 'me'),
          userSecret: const UserSecret(accessToken: 'token'),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(hideLivecureProvider.notifier).setHidden(true);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
  });

  test('⚠⚠ ホーム: 実況が上限（10 ページ）を超えて続いても、次の続き読みはその先から進む', () async {
    // 新しい側 20 件は出る / 続く 220 件（11 ページ）は実況 / 残り 20 件は出る。
    final all = [
      for (var n = 260; n >= 1; n--) _post(n, livecure: n <= 240 && n > 20),
    ];
    final adapter = _PagedAdapter(all);
    final container = await _container(adapter);
    const key = (account: _meKey, type: TimelineType.home);
    final p = timelineProvider(key);
    container.listen(p, (_, _) {}, fireImmediately: true);

    final first = await container.read(p.future);
    expect(first.posts.length, 20);

    // 1 回目: 10 ページ引いても全部実況。何も足されず、入口を出す印が立つ。
    await container.read(p.notifier).loadMore();
    final afterOne = container.read(p).requireValue;
    expect(afterOne.posts.length, 20);
    expect(afterOne.pageCapHit, isTrue);
    expect(afterOne.hasMore, isTrue);

    // 2 回目: ⚠⚠ 同じ 10 ページを引き直さず、その先から進む。
    await container.read(p.notifier).loadMore();
    final afterTwo = container.read(p).requireValue;
    expect(afterTwo.posts.length, 40, reason: '実況の区間を越えて、その先の 20 件が足される');
    expect(afterTwo.posts.last.id, '0001');
    expect(afterTwo.pageCapHit, isFalse);
    expect(
      adapter.requestedMaxIds.toSet().length,
      adapter.requestedMaxIds.length,
      reason: '同じページを 2 度引いていない',
    );
  });

  test('⚠⚠ リスト: 1 ページぶんが全部実況でも、その先の投稿まで続けて引く', () async {
    // 新しい側 20 件は出る / 続く 30 件は実況 / 残り 30 件は出る。
    final all = [
      for (var n = 80; n >= 1; n--) _post(n, livecure: n <= 60 && n > 30),
    ];
    final adapter = _PagedAdapter(all);
    final container = await _container(adapter);
    final p = listTimelineProvider((account: _meKey, id: 'l1'));
    container.listen(p, (_, _) {}, fireImmediately: true);

    final first = await container.read(p.future);
    expect(first.posts.length, 20);

    await container.read(p.notifier).loadMore();
    final after = container.read(p).requireValue;
    expect(after.posts.length, greaterThan(20), reason: '空振りで終わらず、実況の区間の先まで引く');
    expect(after.posts[20].id, '0030');
    expect(after.pageCapHit, isFalse);
    expect(
      adapter.requestedMaxIds.toSet().length,
      adapter.requestedMaxIds.length,
      reason: '同じページを 2 度引いていない',
    );
  });

  test('リスト: 上限（5 ページ）まで全部実況なら入口を出し、次はその先から進む', () async {
    // 新しい側 20 件は出る / 続く 120 件（6 ページ）は実況 / 残り 20 件は出る。
    final all = [
      for (var n = 160; n >= 1; n--) _post(n, livecure: n <= 140 && n > 20),
    ];
    final adapter = _PagedAdapter(all);
    final container = await _container(adapter);
    final p = listTimelineProvider((account: _meKey, id: 'l1'));
    container.listen(p, (_, _) {}, fireImmediately: true);
    await container.read(p.future);

    await container.read(p.notifier).loadMore();
    final afterOne = container.read(p).requireValue;
    expect(afterOne.posts.length, 20);
    expect(afterOne.pageCapHit, isTrue);

    await container.read(p.notifier).loadMore();
    final afterTwo = container.read(p).requireValue;
    expect(afterTwo.posts.length, 40);
    expect(afterTwo.posts.last.id, '0001');
  });

  test('⚠⚠ リスト: 続き読みの途中で読み直したら、古い続き読みは一覧も起点も書き換えない', () async {
    final all = [for (var n = 80; n >= 1; n--) _post(n, livecure: false)];
    final adapter = _PagedAdapter(all);
    final container = await _container(adapter);
    final p = listTimelineProvider((account: _meKey, id: 'l1'));
    container.listen(p, (_, _) {}, fireImmediately: true);
    await container.read(p.future);

    // 続き読みを、取得の途中で止めておく。
    final gate = Completer<void>();
    adapter.gate = gate;
    final pending = container.read(p.notifier).loadMore();
    await Future<void>.delayed(Duration.zero);

    // その間に読み直す（引っ張って更新・アカウント切り替えと同じ形）。
    adapter.gate = null;
    container.invalidate(p);
    final rebuilt = await container.read(p.future);
    expect(rebuilt.posts.length, 20);

    gate.complete();
    await pending;
    final after = container.read(p).requireValue;
    expect(after.posts.length, 20, reason: '古い続き読みのページを足さない');

    // ⚠⚠ 次の続き読みは、読み直した一覧の末尾から進む。
    adapter.requestedMaxIds.clear();
    await container.read(p.notifier).loadMore();
    expect(adapter.requestedMaxIds.first, '0061');
    expect(container.read(p).requireValue.posts.length, 40);
  });

  test('⚠⚠ ホーム: 続き読みの途中で読み直したら、古い続き読みは一覧も起点も書き換えない', () async {
    final all = [for (var n = 80; n >= 1; n--) _post(n, livecure: false)];
    final adapter = _PagedAdapter(all);
    final container = await _container(adapter);
    const key = (account: _meKey, type: TimelineType.home);
    final p = timelineProvider(key);
    container.listen(p, (_, _) {}, fireImmediately: true);
    await container.read(p.future);

    final gate = Completer<void>();
    adapter.gate = gate;
    final pending = container.read(p.notifier).loadMore();
    await Future<void>.delayed(Duration.zero);

    adapter.gate = null;
    container.invalidate(p);
    final rebuilt = await container.read(p.future);
    expect(rebuilt.posts.length, 20);

    gate.complete();
    await pending;
    expect(
      container.read(p).requireValue.posts.length,
      20,
      reason: '古い続き読みのページを足さない',
    );

    adapter.requestedMaxIds.clear();
    await container.read(p.notifier).loadMore();
    expect(adapter.requestedMaxIds.first, '0061');
    expect(container.read(p).requireValue.posts.length, 40);
  });

  // #1293: 以前は起点を書くのがループを抜けたあとだけで、途中のページで失敗すると
  // 再試行が 1 枚目（全部実況のページ）から引き直していた。
  test('⚠⚠ ホーム: 途中のページで失敗しても、再試行は引いたページの先から', () async {
    // 新しい側 20 件は出る / 続く 40 件（2 ページ）は実況 / 残り 20 件は出る。
    final all = [
      for (var n = 80; n >= 1; n--) _post(n, livecure: n <= 60 && n > 20),
    ];
    final adapter = _PagedAdapter(all);
    final container = await _container(adapter);
    const key = (account: _meKey, type: TimelineType.home);
    final p = timelineProvider(key);
    container.listen(p, (_, _) {}, fireImmediately: true);
    await container.read(p.future);

    // 2 枚目（実況のページの続き）の取得で 1 回だけ落ちる。
    adapter.failOnceAt = '0041';
    adapter.requestedMaxIds.clear();
    await container.read(p.notifier).loadMore();

    expect(adapter.requestedMaxIds, [
      '0061', // 1 枚目: 全部実況
      '0041', // 2 枚目: ここで落ちる
      '0041', // ⚠⚠ 再試行は 2 枚目から（以前は '0061' から引き直した）
      '0021', // その先の 20 件
    ]);
    expect(container.read(p).requireValue.posts.length, 40);
  });
}

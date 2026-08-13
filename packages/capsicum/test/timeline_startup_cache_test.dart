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
  _FakeAdapter({
    required this.fresh,
    this.fetchGate,
    this.failFetch = false,
    this.olderPages = const {},
  });

  /// getTimeline が返す「サーバー側の」投稿。
  final List<Post> fresh;

  /// 非 null のとき、getTimeline はこの gate が完了するまで待つ。
  final Future<void>? fetchGate;

  /// true のとき getTimeline は投げる（オフライン起動・5xx 相当）。
  final bool failFetch;

  /// loadMore（maxId 指定）が返す「その maxId より古いページ」。既定は空
  /// （従来どおり「これ以上無い」）。#942 の窓中 loadMore を試すために使う。
  final Map<String, List<Post>> olderPages;

  int fetchCount = 0;

  /// getTimeline に渡された maxId の履歴（null = 初回ページ）。#942 で「どの id を
  /// 起点に続きを取ったか」を確かめるのに使う。
  final List<String?> seenMaxIds = [];

  @override
  AdapterCapabilities get capabilities => _FakeCapabilities();

  @override
  Future<TimelineResponse> getTimeline(
    TimelineType type, {
    TimelineQuery? query,
  }) async {
    fetchCount++;
    // gate を待つ前に記録する（窓中に「maxId 指定の取得へ入ったか」を待たずに
    // 観測できるように）。
    seenMaxIds.add(query?.maxId);
    if (fetchGate != null) await fetchGate;
    if (failFetch) throw Exception('network down');
    if (query?.maxId != null) {
      final older = olderPages[query!.maxId] ?? const <Post>[];
      return TimelineResponse(
        posts: older,
        rawCount: older.length,
        rawLastId: older.isNotEmpty ? older.last.id : null,
        rawJson: [
          for (final p in older) {'id': p.id, 'content': p.content},
        ],
      );
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

/// テストから差し替えられる「現在のアカウント」。[currentAccountProvider] は
/// これを watch する形で override する。
final _selectedAccount = StateProvider<Account?>((ref) => null);

Account _accountFor(_FakeAdapter adapter, {String username = 'me'}) => Account(
  key: AccountKey(
    type: BackendType.mastodon,
    host: 'example.test',
    username: username,
  ),
  adapter: adapter,
  user: User(id: username, username: username),
  userSecret: const UserSecret(accessToken: 'token'),
);

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

  tearDown(() async {
    // 保存は `unawaited` で投げられるので、テスト本体が終わった時点でも書き込みが
    // [TimelineCache] の直列化キューに残りうる。**Windows は開いているファイルを
    // 削除できない**ため、待たずに消すと tearDown が errno 32（プロセスはファイルに
    // アクセスできません）で落ちる。POSIX は開いたまま消せるので Linux CI では
    // 通ってしまい、Windows 実機でだけこのファイルが 4 件赤くなっていた。
    //
    // clear() は save と同じキューに並ぶので、これを待てば先行の書き込みは必ず
    // 終わっている。**directoryOverride を落とす前に**流し切ること（先に null に
    // すると、残った書き込みが実アプリのキャッシュ場所を引きに行って
    // MissingPluginException になる）。
    try {
      await TimelineCache.clear();
    } catch (_) {
      // 後始末の失敗はテスト結果に影響しない。
    }
    TimelineCache.directoryOverride = null;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  ProviderContainer makeContainer(_FakeAdapter adapter) {
    final container = ProviderContainer(
      overrides: [
        // アカウント切替を試験できるよう、値を差し替えられる provider 越しに
        // 渡す（`updateOverrides` は Provider の値を再評価しない）。
        _selectedAccount.overrideWith((ref) => _accountFor(adapter)),
        currentAccountProvider.overrideWith(
          (ref) => ref.watch(_selectedAccount),
        ),
      ],
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
    // 保存は unawaited で、静的な書き込みキュー (_writeQueue) 越しに直列化される
    // （Linux では新規作成時に chmod サブプロセスも挟む）。固定 delay だと CI の
    // 負荷でレースするため、書き上がるまでポーリングする (#958)。
    List<Map<String, dynamic>>? saved;
    for (var i = 0; i < 200 && saved == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      saved = await TimelineCache.load(contextKeyFor(), now: DateTime.now());
    }
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

  /// 裏の取得が「もう用済みか」の判定（#890 / #914 §5）。
  ///
  /// **これは §5 の退行テストではない。** §5 で直したのは「state がまだ
  /// `AsyncLoading` の間は文脈を比較できない」という構造の問題で、現状は
  /// REST 往復が挟まるため世代カウンタ側が先に効き、旧実装でもこのテストは
  /// 通る（実際に確認済み）。ここで固定するのは**アカウント切替をまたいで
  /// 古い結果が state を上書きしない**という不変条件そのもので、これまで
  /// どのテストも押さえていなかった。
  test('先出しの裏で走る取得は、途中でアカウントが切り替わったら state を上書きしない', () async {
    await TimelineCache.save(contextKeyFor(), [
      {'id': 'cached1', 'content': '前回の投稿'},
    ], now: DateTime.now());

    // 裏の取得は gate を開けるまで返らない。その間にアカウントを切り替える。
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

    // 別アカウントへ切替 → build() がやり直され、担当する文脈が変わる。
    final otherAdapter = _FakeAdapter(fresh: [_post('other1')]);
    container.read(_selectedAccount.notifier).state = _accountFor(
      otherAdapter,
      username: 'other',
    );
    final switched = await container.read(timelineProvider.future);
    expect(switched.posts.map((p) => p.id), [
      'other1',
    ], reason: '前提: 切替後の一覧が出ている');

    // 古い文脈の取得がここで完了する。もう担当していないので捨てられること。
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final after = container.read(timelineProvider).value!;
    expect(after.posts.map((p) => p.id), [
      'other1',
    ], reason: '切替前のアカウントの取得結果が、切替後の一覧を上書きしない');
    expect(after.contextKey, isNot(equals(contextKeyFor())));
  });

  /// #958-1: 先出しの窓の**外**（build() 再実行＝pull-to-refresh / タブ・アカウント
  /// 切替）で取得している最中にブロックすると、取得前の生 JSON（ブロック相手の投稿を
  /// 含む）が `clear()` の後ろに save されて復活していた。窓の内側は
  /// `_windowBlockedUserIds` で防いでいたが、窓の外は取得開始からの `_removalSeq` の
  /// 変化で塞ぐ。
  test('取得中にブロックしたら（窓の外でも）その一覧を書き戻さない (#958)', () async {
    // 取得を gate で止め、その隙にブロックする（＝窓ではない直接取得の最中）。
    final gate = Completer<void>();
    final adapter = _FakeAdapter(
      fresh: [_post('blocked1')],
      fetchGate: gate.future,
    );
    final container = makeContainer(adapter);
    addTearDown(container.dispose);

    // build() を起こし、_loadInitial を gate 上の getTimeline で待たせる。
    final future = container.read(timelineProvider.future);
    // getTimeline に入る＝取得開始（世代を控えた後）まで進める。ここより後の
    // ブロックだけが「取得を跨いだ」ケースになる。
    while (adapter.fetchCount == 0) {
      await Future<void>.delayed(Duration.zero);
    }

    // visible_timeline 相当: 一覧からの除去 + キャッシュ clear。除去で世代が進む。
    container.read(timelineProvider.notifier).removePostsByUser('u1');
    await TimelineCache.clear();

    // 取得完了 → save に到達するが、世代が進んでいるので書かない。
    gate.complete();
    await future;
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(
      await TimelineCache.load(contextKeyFor(), now: DateTime.now()),
      isNull,
      reason: 'ブロックを跨いだ取得結果を clear の後ろに書き戻さない',
    );
  });

  /// #942: 先出しの窓（fresh 未着）の間に下端へ達して loadMore が走ると、旧実装は
  /// cached-last を起点に古いページを取ってしまい、直後に届く fresh の全置換で
  /// 捨てられる（重なり無し）／ギャップが残る（後着）。権威ページが着くのを待って
  /// から、その最深を起点に続きを取る。
  test('窓の間の loadMore は fresh を待ってからその最深を起点に続きを取る (#942)', () async {
    await TimelineCache.save(contextKeyFor(), [
      {'id': '200', 'content': '前回1'},
      {'id': '100', 'content': '前回2'},
    ], now: DateTime.now());

    // fresh はキャッシュと重ならない新しいページ（＝旧実装なら loadMore ぶんが
    // 全置換で消えるケース）。続きは fresh 最深 '800' の下にだけ用意する。
    final gate = Completer<void>();
    final adapter = _FakeAdapter(
      fresh: [_post('900'), _post('800')],
      fetchGate: gate.future,
      olderPages: {
        '800': [_post('700')],
      },
    );
    final container = makeContainer(adapter);
    addTearDown(container.dispose);

    final first = await container.read(timelineProvider.future);
    expect(first.fromCache, isTrue);
    expect(first.posts.map((p) => p.id), ['200', '100']);

    // 窓が開いている（fresh 未着）間に loadMore。
    final loadMore = container.read(timelineProvider.notifier).loadMore();
    await Future<void>.delayed(Duration.zero);

    // fresh が着く前は、cached-last(100) を起点にした続き取得へ入っていない。
    expect(
      adapter.seenMaxIds.where((m) => m != null),
      isEmpty,
      reason: 'fresh を待たずに cached-last を起点にした古いページを取らない',
    );

    // fresh を解放 → 窓が閉じ、loadMore は fresh の最深から続きを取る。
    gate.complete();
    await loadMore;
    await Future<void>.delayed(Duration.zero);

    final after = container.read(timelineProvider).value!;
    expect(after.posts.map((p) => p.id), [
      '900',
      '800',
      '700',
    ], reason: '権威ページに続きが正しく連結され、loadMore ぶんが捨てられない');
    expect(
      adapter.seenMaxIds.where((m) => m != null),
      ['800'],
      reason: 'cached-last(100) ではなく fresh の最深(800) を起点にする',
    );
  });

  // Linux 限定 (#958)。キャッシュには生のホーム TL（フォロワー限定 / DM 本文）が
  // 入るので、同ホストの別ユーザーから読めてはいけない。他 OS では chmod 経路が
  // そもそも走らないので skip する。
  group('Linux: キャッシュのパーミッション (#958)', () {
    Future<void> saveOne() => TimelineCache.save('home', [
      {'id': '1', 'content': 'secret'},
    ], now: DateTime.utc(2026, 8, 13));

    int modeOf(File file) => file.statSync().mode & 0x3F;

    test('新規作成したキャッシュは所有者しか読めない', () async {
      await saveOne();

      final file = File('${dir.path}/home_timeline_cache.json');
      expect(file.existsSync(), isTrue);
      expect(modeOf(file), 0, reason: 'group / other に許可ビットが残っている');
    });

    test('v1.55 以前から残っている 0644 のキャッシュも絞り直す', () async {
      // 更新してきたユーザーの状態を作る。ファイル名・保存先は v1.55 と同じなので
      // 「新規作成時だけ chmod」だとここが永久に 0644 のままになる。
      final file = File('${dir.path}/home_timeline_cache.json')
        ..writeAsStringSync('{"contextKey":"home","posts":[]}');
      await Process.run('chmod', ['644', file.path]);
      expect(modeOf(file), isNot(0), reason: '前提が作れていない');

      await saveOne();

      expect(modeOf(file), 0, reason: '既存ファイルが 0644 のまま取り残されている');
      expect(
        file.readAsStringSync(),
        contains('secret'),
        reason: '絞り直しのために本文が書けなくなっている',
      );
    });
  }, skip: !Platform.isLinux);
}

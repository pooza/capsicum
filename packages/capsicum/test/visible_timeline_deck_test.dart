// #1099: #887 の保証（ブロック / ミュートした相手が、見えているどの TL からも
// 消える）をデッキで再定義する（B-3）。
//
// ⚠⚠ **判定軸は「可視」ではなく「列にある同じアカウントのカラム全部」**
// （`docs/deck-ui-plan.md` 未決事項 3 の決着）。可視カラムだけにすると、画面外の
// カラムに相手の投稿が残り、**横へスクロールすると出てくる**。
//
// ⚠⚠ **アカウント A でブロックした相手が、アカウント B のカラムには依然として
// 出るのが正しい。**`removePostsByUser` が受け取るのは**サーバー内 id** なので、
// 絞らないと**同一サーバーに 2 アカウントを持つ人**で誤爆する。

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/deck_provider.dart';
import 'package:capsicum/src/provider/hashtag_provider.dart';
import 'package:capsicum/src/provider/list_provider.dart';
import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum/src/ui/util/visible_timeline.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAdapter extends Mock
    implements DecentralizedBackendAdapter, HashtagSupport, ListSupport {
  @override
  AdapterCapabilities get capabilities => _FakeCapabilities();

  @override
  Future<List<Post>> getPostsByHashtag(
    String hashtag, {
    TimelineQuery? query,
    List<String>? all,
  }) async => query?.maxId == null ? _posts : const [];

  @override
  Future<List<Post>> getListTimeline(String id, {TimelineQuery? query}) async =>
      query?.maxId == null ? _posts : const [];

  @override
  Future<TimelineResponse> getTimeline(
    TimelineType type, {
    TimelineQuery? query,
  }) async => query?.maxId == null
      ? TimelineResponse(posts: _posts, rawCount: _posts.length)
      : const TimelineResponse(posts: [], rawCount: 0);
}

class _FakeCapabilities extends Mock implements AdapterCapabilities {
  @override
  Set<TimelineType> get supportedTimelines => {TimelineType.home};
}

Post _post(String id, String authorId) => Post(
  id: id,
  postedAt: DateTime.utc(2026, 9, 19),
  author: User(id: authorId, username: authorId),
  content: '#capsicum',
);

/// ⚠ ブロックする相手 (`blocked`) の投稿と、そうでない投稿を両方入れておく。
/// 「全部消える」実装でも通ってしまうテストにしない。
final _posts = [_post('3', 'blocked'), _post('2', 'innocent')];

const _host = 'example.test';
const _me = AccountKey(type: BackendType.misskey, host: _host, username: 'me');

/// ⚠⚠ **同じサーバーの別アカウント。**`removePostsByUser` の id はサーバー内 id
/// なので、ここを混ぜると誤爆する（別サーバー同士なら偶然一致しないが、同一
/// サーバーの 2 アカウントでは一致する）。
const _other = AccountKey(
  type: BackendType.misskey,
  host: _host,
  username: 'other',
);

Account _account(AccountKey key) => Account(
  key: key,
  adapter: _FakeAdapter(),
  user: User(id: key.username, username: key.username),
  userSecret: const UserSecret(accessToken: 'token'),
);

class _TestAccountNotifier extends AccountManagerNotifier {
  _TestAccountNotifier(this._accounts);

  final List<Account> _accounts;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: _accounts, current: _accounts.first);
}

/// `ref` を外へ渡しつつ、渡された provider を watch し続ける板。
///
/// ⚠ watch させるのは、**列にあるカラムの TL が生きている**状態（決定済み事項
/// 5-3）を作るため。デッキ画面は画面外のカラムも `Row` で組み立て続けるので、
/// 実物でも同じく生きている。
class _Probe extends ConsumerWidget {
  const _Probe({required this.onRef, this.alive = const []});

  final void Function(WidgetRef ref) onRef;
  final List<ProviderListenable<Object?>> alive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    for (final provider in alive) {
      ref.watch(provider);
    }
    onRef(ref);
    return const SizedBox.shrink();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const homeKey = (account: _me, type: TimelineType.home);
  const tagKey = (account: _me, spec: 'capsicum');
  const listKey = (account: _me, id: 'l1');
  const otherTagKey = (account: _other, spec: 'capsicum');

  /// 列（`deck_columns`）を用意してルートのコンテナを作る。
  ///
  /// [mountedDecks] が 0 ならデッキは閉じている扱い。
  Future<ProviderContainer> makeRoot({
    required List<String> columns,
    int mountedDecks = 1,
    TabType selectedTab = const TimelineTab(TimelineType.home),
  }) async {
    SharedPreferences.setMockInitialValues({'deck_columns': columns});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    return ProviderContainer(
      overrides: [
        accountManagerProvider.overrideWith(
          () => _TestAccountNotifier([_account(_me), _account(_other)]),
        ),
        mountedDeckCountProvider.overrideWith((ref) => mountedDecks),
        selectedTabProvider.overrideWith((ref) => selectedTab),
      ],
    );
  }

  /// 列の 1 行。`<id>|<アカウント>|<種別>`。
  String column(String id, AccountKey account, String tab) =>
      '$id|${account.toStorageKey()}|$tab';

  Future<WidgetRef> pumpProbe(
    WidgetTester tester,
    ProviderContainer container, {
    List<ProviderListenable<Object?>> alive = const [],
    ProviderContainer? scope,
  }) async {
    late WidgetRef captured;
    final probe = _Probe(onRef: (ref) => captured = ref, alive: alive);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: scope == null
              ? probe
              : UncontrolledProviderScope(container: scope, child: probe),
        ),
      ),
    );
    return captured;
  }

  group('ブロックの反映先は「列にある同じアカウントのカラム全部」', () {
    testWidgets('⚠⚠ 画面に入っていないカラムからも消える（列にあれば消す）', (tester) async {
      // ⚠ 3 本目（リスト）は幅の都合で画面外にあるつもりのカラム。**可視判定を
      // 持たない**ので、実装上は 1 本目と区別されない。ここが #1099 の要点で、
      // 「可視カラムだけ」に戻すとこのテストが落ちる。
      final root = await makeRoot(
        columns: [
          column('c1', _me, 'timeline:home'),
          column('c2', _me, 'hashtag:capsicum'),
          column('c3', _me, 'list:l1'),
        ],
      );
      addTearDown(root.dispose);

      final ref = await pumpProbe(
        tester,
        root,
        alive: [
          timelineProvider(homeKey),
          hashtagTimelineProvider(tagKey),
          listTimelineProvider(listKey),
        ],
      );
      await root.read(timelineProvider(homeKey).future);
      await root.read(hashtagTimelineProvider(tagKey).future);
      await root.read(listTimelineProvider(listKey).future);

      readVisibleTimelines(ref).removePostsByUser('blocked');

      expect(
        root.read(timelineProvider(homeKey)).value!.posts.map((p) => p.id),
        ['2'],
      );
      expect(
        root
            .read(hashtagTimelineProvider(tagKey))
            .value!
            .posts
            .map((p) => p.id),
        ['2'],
        reason: 'タグのカラムからも消える',
      );
      expect(
        root.read(listTimelineProvider(listKey)).value!.posts.map((p) => p.id),
        ['2'],
        reason: '画面外のリストのカラムからも消える',
      );
    });

    testWidgets('⚠⚠ 同じサーバーの別アカウントのカラムには触らない', (tester) async {
      final root = await makeRoot(
        columns: [
          column('c1', _me, 'hashtag:capsicum'),
          column('c2', _other, 'hashtag:capsicum'),
        ],
      );
      addTearDown(root.dispose);

      final ref = await pumpProbe(
        tester,
        root,
        alive: [hashtagTimelineProvider(tagKey)],
      );
      await root.read(hashtagTimelineProvider(tagKey).future);

      readVisibleTimelines(ref).removePostsByUser('blocked');

      expect(
        root
            .read(hashtagTimelineProvider(tagKey))
            .value!
            .posts
            .map((p) => p.id),
        ['2'],
        reason: '自分のカラムからは消える',
      );
      // ⚠ 「消えない」ではなく「そもそも起こさない」で見る。別アカウントの TL を
      // `ref.read` で起こすこと自体が、誰も見ていない provider の REST 無駄打ち。
      expect(
        root.exists(hashtagTimelineProvider(otherTagKey)),
        isFalse,
        reason: 'アカウント B のブロック関係は別。B のカラムは触らない',
      );
    });
  });

  group('デッキが閉じているとき', () {
    testWidgets('⚠ 列にカラムが残っていても読まない（片づいた provider を起こさない）', (tester) async {
      // `deckColumnsProvider` は永続化された構成なので、閉じていても中身は残る。
      // そこを無条件に読むと、autoDispose で片づいたはずの TL を `ref.read` で
      // 起こし、結果が誰にも使われないまま REST を数ページ叩く。
      final root = await makeRoot(
        columns: [
          column('c1', _me, 'hashtag:capsicum'),
          column('c2', _me, 'list:l1'),
        ],
        mountedDecks: 0,
      );
      addTearDown(root.dispose);

      final ref = await pumpProbe(tester, root);
      readVisibleTimelines(ref).removePostsByUser('blocked');

      expect(root.exists(hashtagTimelineProvider(tagKey)), isFalse);
      expect(root.exists(listTimelineProvider(listKey)), isFalse);
    });
  });

  group('カラムのスコープではタブ UI を解決しない', () {
    testWidgets('⚠⚠ ルートで選ばれているタブを、カラムのアカウントに当てない', (tester) async {
      // 選択中タブはアカウントに依存しない**単数**の状態。カラムのスコープ
      // （`currentAccountProvider` を上書きした子コンテナ）でそのまま読むと、
      // 「アカウント B の #nowhere」という誰も見ていない TL が起きる。
      final root = await makeRoot(
        columns: [column('c1', _other, 'hashtag:capsicum')],
        selectedTab: const HashtagTab('nowhere'),
      );
      addTearDown(root.dispose);

      final scope = ProviderContainer(
        parent: root,
        overrides: [
          currentAccountProvider.overrideWithValue(_account(_other)),
          inDeckColumnProvider.overrideWithValue(true),
        ],
      );
      addTearDown(scope.dispose);

      final ref = await pumpProbe(tester, root, scope: scope);
      readVisibleTimelines(ref).removePostsByUser('blocked');

      // ⚠⚠ **見るのは子コンテナ。**スコープつきの provider をカラムのスコープで
      // 起こすと、インスタンスはそちら側にできる。ルートだけ見ていると、穴を
      // 開けてもテストが通ってしまう（2026-09-20 に実際に空振りさせて確認した）。
      expect(
        scope.exists(
          hashtagTimelineProvider((account: _other, spec: 'nowhere')),
        ),
        isFalse,
        reason: 'ルートのタブ（#nowhere）はこのカラムのアカウントのものではない',
      );
      expect(
        root.exists(
          hashtagTimelineProvider((account: _other, spec: 'nowhere')),
        ),
        isFalse,
        reason: 'ルート側にも作らない',
      );
    });
  });
}

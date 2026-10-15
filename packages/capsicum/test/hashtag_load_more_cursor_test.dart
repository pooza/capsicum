import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/hashtag_provider.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// タグ TL の続き読みは、**絞る前の**末尾を起点に進む（v2.2 のリリース前
/// レビュー・#1209）。
///
/// Misskey は除外（「含まない」）をサーバーで絞れないので、端末側で落とす。
/// 続き読みの起点を「表示中の最後の投稿」にしていたため、除外に当たる投稿が
/// 1 ページぶん続くと、同じページを引き直し続けて先へ進めなかった。
class _FakeCapabilities extends Mock implements AdapterCapabilities {
  @override
  Set<TimelineType> get supportedTimelines => {TimelineType.home};
}

/// 新しい順に並んだ投稿を、`maxId` より古い側から 1 ページずつ返す。
class _PagedAdapter extends Mock
    implements DecentralizedBackendAdapter, HashtagSupport {
  _PagedAdapter(this.all);

  final List<Post> all;
  final List<String?> requestedMaxIds = [];

  @override
  AdapterCapabilities get capabilities => _FakeCapabilities();

  @override
  Future<List<Post>> getPostsByHashtag(
    HashtagQuery hashtag, {
    TimelineQuery? query,
  }) async {
    final maxId = query?.maxId;
    requestedMaxIds.add(maxId);
    final start = maxId == null ? 0 : all.indexWhere((p) => p.id == maxId) + 1;
    return all.skip(start).take(query?.limit ?? 20).toList();
  }
}

const _meKey = AccountKey(
  type: BackendType.misskey,
  host: 'example.test',
  username: 'me',
);

Post _post(int n, {required bool excluded}) => Post(
  // 新しいほど大きい id（並びは降順で渡す）。
  id: n.toString().padLeft(4, '0'),
  postedAt: DateTime.utc(2026, 10, 12),
  author: const User(id: 'u1', username: 'u1'),
  content: 'body',
  tags: excluded ? const ['a', 'b'] : const ['a'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
  });

  test('⚠⚠ 除外に当たる投稿が 1 ページ以上続いても、その先へ進む', () async {
    // 100 件。新しい側 20 件は出る / 続く 45 件は除外（2 ページ強）/ 残り 35 件は出る。
    final all = [
      for (var n = 100; n >= 1; n--) _post(n, excluded: n <= 80 && n > 35),
    ];
    final adapter = _PagedAdapter(all);
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

    // 「a を含み、b を含まない」。
    final p = hashtagTimelineProvider((account: _meKey, spec: 'a!b'));
    container.listen(p, (_, _) {}, fireImmediately: true);
    final first = await container.read(p.future);
    expect(first.posts.map((e) => e.id), [
      for (var n = 100; n > 80; n--) n.toString().padLeft(4, '0'),
    ]);

    await container.read(p.notifier).loadMore();
    final afterOne = container.read(p).requireValue;
    expect(
      afterOne.posts.length,
      greaterThan(20),
      reason: '除外の区間を越えて、その先の投稿が足される（空振りで終わらない）',
    );
    expect(afterOne.posts[20].id, '0035');
    expect(afterOne.hasMore, isTrue);

    // 起点が生の末尾で進んでいること（同じページを引き直していない）。
    expect(
      adapter.requestedMaxIds.toSet().length,
      adapter.requestedMaxIds.length,
    );

    await container.read(p.notifier).loadMore();
    final afterTwo = container.read(p).requireValue;
    expect(afterTwo.posts.last.id, '0001');
    expect(afterTwo.posts.length, 55);
    // 表示された投稿に、除外のタグを持つものは無い。
    expect(afterTwo.posts.every((e) => !e.tags.contains('b')), isTrue);
  });

  // #1283（v2.2 のリリース PR の締めの Codex レビュー・P2）。
  test('⚠⚠ 最初の読み込みが上限まで引いて空でも、続き読みはその先から進む', () async {
    // 260 件。新しい側 220 件（11 ページぶん）は除外 / 残り 40 件は出る。
    // 最初の読み込みは 10 ページ（200 件）で打ち切られ、1 件も残らない。
    final all = [for (var n = 260; n >= 1; n--) _post(n, excluded: n > 40)];
    final adapter = _PagedAdapter(all);
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

    final p = hashtagTimelineProvider((account: _meKey, spec: 'a!b'));
    container.listen(p, (_, _) {}, fireImmediately: true);
    final first = await container.read(p.future);
    expect(first.posts, isEmpty);
    expect(first.hasMore, isTrue, reason: '画面はここから続きを読む入口を出す');
    expect(first.pageCapHit, isTrue);
    expect(adapter.requestedMaxIds.length, 10);

    await container.read(p.notifier).loadMore();
    final after = container.read(p).requireValue;
    expect(
      after.posts,
      isNotEmpty,
      reason: '最初の読み込みで進んだ先（201 件め以降）から引く。先頭から引き直さない',
    );
    expect(after.posts.first.id, '0040');
    // 11 回めの起点は、最初の読み込みの生の末尾（200 件め = 0061）。
    expect(adapter.requestedMaxIds[10], '0061');
    // 同じページを 2 度引いていない（先頭の null も 1 回だけ）。
    expect(
      adapter.requestedMaxIds.toSet().length,
      adapter.requestedMaxIds.length,
    );
  });
}

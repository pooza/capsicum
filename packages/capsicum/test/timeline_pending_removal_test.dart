import 'dart:async';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TL 上部から離れている間、streaming の新着は一覧ではなく未表示バッファへ溜まり、
/// 「新着 N 件」を押したときに初めて出る (#296)。
///
/// 削除・ブロック・ミュートが一覧からしか消していないと、**消したはずの投稿が
/// 「新着 N 件」を開いた瞬間に現れる**。ブロックは安全のための操作なので、
/// 「見えているどの TL からも消える」保証 (#887) をこのバッファにも効かせる。
class _StreamingFakeAdapter extends Mock
    implements DecentralizedBackendAdapter, StreamSupport {
  _StreamingFakeAdapter(this.initial);

  final List<Post> initial;
  final _controller = StreamController<Post>.broadcast();

  void emit(Post post) => _controller.add(post);

  @override
  AdapterCapabilities get capabilities => _FakeCapabilities();

  @override
  Future<TimelineResponse> getTimeline(
    TimelineType type, {
    TimelineQuery? query,
  }) async {
    if (query?.maxId != null) {
      return const TimelineResponse(posts: [], rawCount: 0);
    }
    return TimelineResponse(
      posts: initial,
      rawCount: initial.length,
      rawLastId: initial.isNotEmpty ? initial.last.id : null,
    );
  }

  @override
  Stream<Post> streamTimeline(
    TimelineType type, {
    void Function(Object error, StackTrace stack)? onParseError,
    void Function(Object error, StackTrace stack)? onStreamError,
    void Function()? onReconnectExhausted,
    void Function(StreamConnectionState state)? onConnectionState,
    void Function(int? closeCode, String? closeReason)? onDisconnect,
  }) => _controller.stream;

  @override
  void disposeStream() {}
}

class _FakeCapabilities extends Mock implements AdapterCapabilities {
  @override
  Set<TimelineType> get supportedTimelines => {TimelineType.home};
}

Post _post(String id, {String authorId = 'u1'}) => Post(
  id: id,
  postedAt: DateTime.utc(2026, 8, 1),
  author: User(id: authorId, username: authorId),
  content: 'body $id',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    TimelineNotifier.resetStartupStateForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
  });

  ProviderContainer makeContainer(_StreamingFakeAdapter adapter) {
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
    container.listen(timelineProvider, (_, _) {}, fireImmediately: true);
    return container;
  }

  /// 未表示バッファに 1 件溜めた状態を作る。
  Future<(ProviderContainer, TimelineNotifier)> queueOne(
    _StreamingFakeAdapter adapter,
    Post incoming,
  ) async {
    final container = makeContainer(adapter);
    await container.read(timelineProvider.future);
    final notifier = container.read(timelineProvider.notifier);

    // 先頭から離れている＝新着を即座に差し込まない状態にする (#296)。
    notifier.setNearTop(false);
    adapter.emit(incoming);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(timelineProvider).value?.pendingCount,
      1,
      reason: '前提: 新着が未表示バッファに溜まっている',
    );
    return (container, notifier);
  }

  test('ブロックした相手の投稿は未表示バッファからも消える', () async {
    final adapter = _StreamingFakeAdapter([_post('own1')]);
    final (container, notifier) = await queueOne(
      adapter,
      _post('bad1', authorId: 'blocked'),
    );
    addTearDown(container.dispose);

    notifier.removePostsByUser('blocked');

    expect(container.read(timelineProvider).value?.pendingCount, 0);

    notifier.flushPending();
    expect(
      container.read(timelineProvider).value?.posts.map((p) => p.id),
      ['own1'],
      reason: '「新着 N 件」を開いてもブロックした相手の投稿は出てこない',
    );
  });

  test('ブースト元の投稿者でブロックしても未表示バッファから消える', () async {
    final adapter = _StreamingFakeAdapter([_post('own1')]);
    final boost = Post(
      id: 'boost1',
      postedAt: DateTime.utc(2026, 8, 1),
      author: const User(id: 'someone', username: 'someone'),
      reblog: _post('inner1', authorId: 'blocked'),
    );
    final (container, notifier) = await queueOne(adapter, boost);
    addTearDown(container.dispose);

    notifier.removePostsByUser('blocked');

    expect(
      container.read(timelineProvider).value?.pendingCount,
      0,
      reason: 'ブロックした相手をブーストした第三者の投稿も残さない',
    );
  });

  test('削除した投稿は未表示バッファからも消える', () async {
    final adapter = _StreamingFakeAdapter([_post('own1')]);
    final (container, notifier) = await queueOne(adapter, _post('doomed'));
    addTearDown(container.dispose);

    notifier.removePost('doomed');

    expect(container.read(timelineProvider).value?.pendingCount, 0);

    notifier.flushPending();
    expect(container.read(timelineProvider).value?.posts.map((p) => p.id), [
      'own1',
    ]);
  });

  test('無関係な投稿は未表示バッファに残る（消しすぎない）', () async {
    final adapter = _StreamingFakeAdapter([_post('own1')]);
    final (container, notifier) = await queueOne(
      adapter,
      _post('keep1', authorId: 'other'),
    );
    addTearDown(container.dispose);

    notifier.removePostsByUser('blocked');
    notifier.removePost('unrelated');

    expect(container.read(timelineProvider).value?.pendingCount, 1);

    // 取り込み順は id の降順（[TimelineNotifier.flushPending]）なので、
    // ここで見るのは並びではなく「残っていること」。
    notifier.flushPending();
    expect(
      container.read(timelineProvider).value?.posts.map((p) => p.id),
      containsAll(<String>['keep1', 'own1']),
    );
  });
}

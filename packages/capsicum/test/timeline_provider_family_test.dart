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

/// #1087: 本線 TL を `(アカウント, 種別)` の family にする。
///
/// デッキ（#720）の土台。同じアカウントの home と local を並べたとき、
/// **別々のインスタンスが別々の TL を持つ**ことがここで成り立っていないと、
/// カラムを 2 本置いた瞬間に片方の中身がもう片方で上書きされる。
class _RecordingAdapter extends Mock implements DecentralizedBackendAdapter {
  /// getTimeline に渡された種別と maxId の履歴。
  final List<(TimelineType, String?)> calls = [];

  @override
  AdapterCapabilities get capabilities => _FakeCapabilities();

  @override
  Future<TimelineResponse> getTimeline(
    TimelineType type, {
    TimelineQuery? query,
  }) async {
    calls.add((type, query?.maxId));
    if (query?.maxId != null) {
      return const TimelineResponse(posts: [], rawCount: 0);
    }
    // 種別ごとに違う投稿を返し、どのインスタンスがどの TL を持っているかを見分ける。
    final post = Post(
      id: '${type.name}-1',
      postedAt: DateTime.utc(2026, 9, 17),
      author: const User(id: 'u1', username: 'me'),
      content: 'body',
    );
    return TimelineResponse(posts: [post], rawCount: 1, rawLastId: post.id);
  }
}

/// キーごとに購読を持つアダプタ (#1089 / #1090)。どのキーが張られ・閉じられたかを記録する。
class _KeyedStreamingAdapter extends _RecordingAdapter
    implements StreamSupport {
  final Map<String, StreamController<Post>> controllers = {};
  final List<String> disposed = [];

  @override
  Stream<Post> streamTimeline(
    String key,
    TimelineType type, {
    void Function(Object error, StackTrace stack)? onParseError,
    void Function(Object error, StackTrace stack)? onStreamError,
    void Function()? onReconnectExhausted,
    void Function(StreamConnectionState state)? onConnectionState,
    void Function(int? closeCode, String? closeReason)? onDisconnect,
  }) {
    controllers.remove(key)?.close();
    final controller = StreamController<Post>.broadcast();
    controllers[key] = controller;
    return controller.stream;
  }

  @override
  void disposeStream(String key) {
    disposed.add(key);
    controllers.remove(key)?.close();
  }
}

class _FakeCapabilities extends Mock implements AdapterCapabilities {
  @override
  Set<TimelineType> get supportedTimelines => {
    TimelineType.home,
    TimelineType.local,
  };
}

const _meKey = AccountKey(
  type: BackendType.mastodon,
  host: 'example.test',
  username: 'me',
);

const _otherKey = AccountKey(
  type: BackendType.mastodon,
  host: 'example.test',
  username: 'other',
);

Account _account(AccountKey key, DecentralizedBackendAdapter adapter) =>
    Account(
      key: key,
      adapter: adapter,
      user: User(id: key.username, username: key.username),
      userSecret: const UserSecret(accessToken: 'token'),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    TimelineNotifier.resetStartupStateForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
  });

  ProviderContainer makeContainer(_RecordingAdapter adapter) {
    final container = ProviderContainer(
      overrides: [
        currentAccountProvider.overrideWith((ref) => _account(_meKey, adapter)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// autoDispose なので、実アプリで画面が watch し続けているのと同じ状態を作る。
  void keepAlive(ProviderContainer container, TimelineKey key) {
    container.listen(timelineProvider(key), (_, _) {}, fireImmediately: true);
  }

  test('同じアカウント・別種別は別インスタンスで、それぞれ自分の種別を取る', () async {
    final adapter = _RecordingAdapter();
    final container = makeContainer(adapter);
    const home = (account: _meKey, type: TimelineType.home);
    const local = (account: _meKey, type: TimelineType.local);
    keepAlive(container, home);
    keepAlive(container, local);

    final homeState = await container.read(timelineProvider(home).future);
    final localState = await container.read(timelineProvider(local).future);

    expect(
      identical(
        container.read(timelineProvider(home).notifier),
        container.read(timelineProvider(local).notifier),
      ),
      isFalse,
      reason: '同じアカウントでも種別が違えば別の notifier',
    );
    expect(homeState.posts.map((p) => p.id), ['home-1']);
    expect(localState.posts.map((p) => p.id), ['local-1']);
    expect(homeState.contextKey, isNot(localState.contextKey));
  });

  test('値の等しいキーは同じインスタンスを指す（record を作り直しても）', () async {
    final adapter = _RecordingAdapter();
    final container = makeContainer(adapter);
    const key = (account: _meKey, type: TimelineType.home);
    keepAlive(container, key);
    await container.read(timelineProvider(key).future);

    // const でない、別に組み立てた record。
    final rebuilt = (
      account: AccountKey(
        type: BackendType.mastodon,
        host: 'example.test',
        username: ['m', 'e'].join(),
      ),
      type: TimelineType.home,
    );

    expect(
      identical(
        container.read(timelineProvider(key).notifier),
        container.read(timelineProvider(rebuilt).notifier),
      ),
      isTrue,
    );
    expect(adapter.calls.where((c) => c.$2 == null), hasLength(1));
  });

  test('チャンネル等の非 TL タブへ切り替えても、本線のキーは home のまま変わらない', () {
    final adapter = _RecordingAdapter();
    final container = makeContainer(adapter);
    final before = container.read(currentTimelineKeyProvider);

    container.read(selectedTabProvider.notifier).state = const ChannelTab(
      id: 'ch1',
    );

    // キーが変わると「中身は同じホーム TL なのに別インスタンス」になって REST を
    // 取り直す。従来（selectedTimelineTypeProvider が非 TL タブを home に畳む）と
    // 同じく、同じインスタンスを指し続けること。
    expect(container.read(currentTimelineKeyProvider), before);
    expect(before, (account: _meKey, type: TimelineType.home));
  });

  test('キーのアカウントが現在のアカウントと違うインスタンスは、何も取得しない', () async {
    final adapter = _RecordingAdapter();
    final container = makeContainer(adapter);
    // 現在のアカウントは me。other のキーで引く＝切替直後に残った旧インスタンスの形。
    const stale = (account: _otherKey, type: TimelineType.home);
    keepAlive(container, stale);

    final state = await container.read(timelineProvider(stale).future);

    expect(adapter.calls, isEmpty, reason: '別アカウントのアダプタで TL を引かない');
    expect(state.posts, isEmpty);
  });

  test(
    '⚠⚠ 同じアカウントの home と local が別々のキーで購読し、片方の破棄が他方を閉じない (#1089 / #1090)',
    () async {
      final adapter = _KeyedStreamingAdapter();
      final container = ProviderContainer(
        overrides: [
          currentAccountProvider.overrideWith(
            (ref) => _account(_meKey, adapter),
          ),
        ],
      );
      addTearDown(container.dispose);
      const home = (account: _meKey, type: TimelineType.home);
      const local = (account: _meKey, type: TimelineType.local);
      keepAlive(container, home);
      final localSub = container.listen(
        timelineProvider(local),
        (_, _) {},
        fireImmediately: true,
      );
      await container.read(timelineProvider(home).future);
      await container.read(timelineProvider(local).future);

      final homeKey = timelineContextKey(
        _meKey,
        const TimelineTab(TimelineType.home),
      )!;
      final localKey = timelineContextKey(
        _meKey,
        const TimelineTab(TimelineType.local),
      )!;
      expect(adapter.controllers.keys, containsAll([homeKey, localKey]));

      // local のカラムが消えた（誰も watch しなくなった）→ autoDispose。
      localSub.close();
      await Future<void>.delayed(Duration.zero);
      await container.pump();

      expect(adapter.disposed, [localKey], reason: '閉じるのは local のキーだけ');

      // home には引き続き届く。
      adapter.controllers[homeKey]!.add(
        Post(
          id: 'live1',
          postedAt: DateTime.utc(2026, 9, 17),
          author: const User(id: 'u2', username: 'someone'),
          content: 'live',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(timelineProvider(home)).value!.posts.map((p) => p.id),
        contains('live1'),
      );
    },
  );

  test('⚠⚠ 同じカラムを 2 本置いて 1 本だけ外しても購読は止まらず、全部外したときだけ閉じる (#1093)', () async {
    // デッキで重複カラムは同じ provider インスタンスを共有する（決定済み事項 6-2）。
    // 削除時に購読を明示的に止めると、残ったもう 1 本が無音で止まる（6-3）。
    final adapter = _KeyedStreamingAdapter();
    final container = ProviderContainer(
      overrides: [
        currentAccountProvider.overrideWith((ref) => _account(_meKey, adapter)),
      ],
    );
    addTearDown(container.dispose);
    const key = (account: _meKey, type: TimelineType.home);
    final homeKey = timelineContextKey(
      _meKey,
      const TimelineTab(TimelineType.home),
    )!;

    // カラム 2 本ぶんの watch。
    final first = container.listen(
      timelineProvider(key),
      (_, _) {},
      fireImmediately: true,
    );
    final second = container.listen(
      timelineProvider(key),
      (_, _) {},
      fireImmediately: true,
    );
    await container.read(timelineProvider(key).future);
    expect(adapter.controllers.keys, [homeKey], reason: '前提: 購読は 1 本');

    first.close();
    await container.pump();
    expect(adapter.disposed, isEmpty, reason: 'もう 1 本が残っているので閉じない');

    second.close();
    await container.pump();
    expect(adapter.disposed, [
      homeKey,
    ], reason: '最後の 1 本が消えたら autoDispose で閉じる');
  });

  test('loadMore は選択中のタブではなく、キーの種別で続きを取る', () async {
    final adapter = _RecordingAdapter();
    final container = makeContainer(adapter);
    const local = (account: _meKey, type: TimelineType.local);
    keepAlive(container, local);
    await container.read(timelineProvider(local).future);

    // 選択中のタブは home（既定値）のまま。以前は loadMore が
    // selectedTimelineTypeProvider を読んでいたので、ここで home を取りに行っていた。
    expect(container.read(selectedTimelineTypeProvider), TimelineType.home);
    await container.read(timelineProvider(local).notifier).loadMore();

    expect(adapter.calls.where((c) => c.$2 != null).map((c) => c.$1), [
      TimelineType.local,
    ]);
  });
}

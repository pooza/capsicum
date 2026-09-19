import 'dart:async';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本線 TL のライブ購読まわりの挙動を固定する (#1098 の前提)。
///
/// ⚠⚠ **これは #1098 でこの一式を mixin へ切り出す前に置く防壁。**ライブ取り込み
/// ([TimelineNotifier] の `_ingestLivePosts`)・ギャップ補完 (`_catchUpSinceTop`)・
/// 接続状態の state 反映は [#781](https://github.com/pooza/capsicum/issues/781) /
/// [#784](https://github.com/pooza/capsicum/issues/784) /
/// [#714](https://github.com/pooza/capsicum/issues/714) の積み重ねで、**ホーム TL の
/// 本線**。タグ / リスト / チャンネルへ同じ仕組みを広げるために切り出すので、
/// 切り出しの前後で本線の挙動が変わらないことをここで押さえる。
///
/// ⚠ 既存の検査は「family のキー分離」(`timeline_provider_family_test`) と
/// 「未表示バッファからの削除」(`timeline_pending_removal_test`) しか無く、
/// **取り込みそのもの（並び・重複排除・フィルタ・pending への退避）は
/// どこでも固定されていなかった。**

class _FakeCapabilities extends Mock implements AdapterCapabilities {
  @override
  Set<TimelineType> get supportedTimelines => {
    TimelineType.home,
    TimelineType.local,
  };
}

/// ライブ購読を外から駆動できるアダプタ。
///
/// 購読キーごとの [StreamController] と `onConnectionState` を握っておき、
/// テストが「投稿が流れてきた」「live になった」「切れた」を作れるようにする。
class _LiveAdapter extends Mock
    implements DecentralizedBackendAdapter, StreamSupport {
  _LiveAdapter(this.initialPosts);

  /// 初回 REST が返す投稿（新しい順）。
  final List<Post> initialPosts;

  /// 非 null のとき、2 回目以降の `getTimeline` がこれを返す（ギャップ補完用）。
  List<Post>? catchUpPage;

  final Map<String, StreamController<Post>> controllers = {};
  final Map<String, void Function(StreamConnectionState)> connectionCallbacks =
      {};
  final List<String> disposedKeys = [];
  int getTimelineCalls = 0;

  @override
  AdapterCapabilities get capabilities => _FakeCapabilities();

  @override
  Future<TimelineResponse> getTimeline(
    TimelineType type, {
    TimelineQuery? query,
  }) async {
    getTimelineCalls++;
    final page = getTimelineCalls > 1 ? (catchUpPage ?? const <Post>[])
        : initialPosts;
    return TimelineResponse(
      posts: page,
      rawCount: page.length,
      rawLastId: page.isEmpty ? null : page.last.id,
    );
  }

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
    if (onConnectionState != null) connectionCallbacks[key] = onConnectionState;
    return controller.stream;
  }

  @override
  void disposeStream(String key) {
    disposedKeys.add(key);
    controllers.remove(key)?.close();
  }

  /// 購読キーへ投稿を 1 件流す。
  void emit(String key, Post post) => controllers[key]!.add(post);

  /// 接続状態の遷移を起こす。
  void connectionState(String key, StreamConnectionState state) =>
      connectionCallbacks[key]!(state);
}

const _meKey = AccountKey(
  type: BackendType.mastodon,
  host: 'example.test',
  username: 'me',
);

Account _account(DecentralizedBackendAdapter adapter) => Account(
  key: _meKey,
  adapter: adapter,
  user: const User(id: 'me', username: 'me'),
  userSecret: const UserSecret(accessToken: 'token'),
);

Post _post(String id, {String content = 'body', FilterAction? filterAction}) =>
    Post(
      id: id,
      postedAt: DateTime.utc(2026, 9, 19),
      author: const User(id: 'u1', username: 'someone'),
      content: content,
      filterAction: filterAction,
    );

/// ⚠ Mastodon の数値 id。`comparePostIdDesc` が数として比較する側 (#781)。
final _p101 = _post('101');
final _p102 = _post('102');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    TimelineNotifier.resetStartupStateForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
  });

  const key = (account: _meKey, type: TimelineType.home);
  final streamKey = timelineContextKey(_meKey, const TimelineTab(TimelineType.home))!;

  ProviderContainer makeContainer(_LiveAdapter adapter) {
    final container = ProviderContainer(
      overrides: [
        currentAccountProvider.overrideWith((ref) => _account(adapter)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// 画面が watch し続けている状態を作り、初回取得を待つ。
  Future<TimelineNotifier> start(
    ProviderContainer container,
  ) async {
    container.listen(timelineProvider(key), (_, _) {}, fireImmediately: true);
    await container.read(timelineProvider(key).future);
    return container.read(timelineProvider(key).notifier);
  }

  /// streaming の 1 件が state に反映されるまで待つ。
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  TimelineState read(ProviderContainer container) =>
      container.read(timelineProvider(key)).requireValue;

  group('ライブ取り込み — 先頭にいるとき', () {
    test('新着が先頭に入り、id の降順が保たれる', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await start(container);

      adapter.emit(streamKey, _post('103'));
      await settle();

      expect(
        read(container).posts.map((p) => p.id),
        ['103', '102', '101'],
      );
    });

    test('⚠ 古い id が流れてきても降順に差し込まれる（ブロック prepend ではない）', () async {
      // #781: ギャップ補完バッチと streaming の prepend が競合しても並びが崩れない
      // ことを担保している経路。マージ + ソートをやめると落ちる。
      final adapter = _LiveAdapter([_post('105'), _post('101')]);
      final container = makeContainer(adapter);
      await start(container);

      adapter.emit(streamKey, _post('103'));
      await settle();

      expect(read(container).posts.map((p) => p.id), ['105', '103', '101']);
    });

    test('既に表示中の id は二重に取り込まない', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await start(container);

      adapter.emit(streamKey, _post('102'));
      await settle();

      expect(read(container).posts.map((p) => p.id), ['102', '101']);
    });
  });

  group('ライブ取り込み — スクロール中', () {
    test('pending へ積まれ、一覧は動かない（スクロールジャンプを起こさない）', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      final notifier = await start(container);

      notifier.setNearTop(false);
      adapter.emit(streamKey, _post('103'));
      await settle();

      final state = read(container);
      expect(state.posts.map((p) => p.id), ['102', '101']);
      expect(state.pendingCount, 1);
    });

    test('先頭へ戻ると pending が降順で取り込まれ、pendingCount が 0 になる', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      final notifier = await start(container);

      notifier.setNearTop(false);
      adapter.emit(streamKey, _post('104'));
      adapter.emit(streamKey, _post('103'));
      await settle();
      notifier.setNearTop(true);

      final state = read(container);
      expect(state.posts.map((p) => p.id), ['104', '103', '102', '101']);
      expect(state.pendingCount, 0);
    });

    test('pending に居る id と同じものが再度流れても二重にならない', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      final notifier = await start(container);

      notifier.setNearTop(false);
      adapter.emit(streamKey, _post('103'));
      adapter.emit(streamKey, _post('103'));
      await settle();

      expect(read(container).pendingCount, 1);
    });
  });

  group('ライブ取り込み — フィルタ', () {
    test('filterAction が hide の投稿は取り込まない', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await start(container);

      adapter.emit(streamKey, _post('103', filterAction: FilterAction.hide));
      await settle();

      expect(read(container).posts.map((p) => p.id), ['102', '101']);
    });

    test('hideLivecure が ON なら #実況 の投稿は取り込まない', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await container.read(hideLivecureProvider.notifier).setHidden(true);
      await start(container);

      adapter.emit(streamKey, _post('103', content: 'いま見てる #実況'));
      adapter.emit(streamKey, _post('104'));
      await settle();

      expect(read(container).posts.map((p) => p.id), ['104', '102', '101']);
    });
  });

  group('接続状態の state 反映 (#714 / #782)', () {
    test('live / disconnected が state に出る', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await start(container);

      adapter.connectionState(streamKey, StreamConnectionState.disconnected);
      await settle();

      expect(
        read(container).streamConnectionState,
        StreamConnectionState.disconnected,
      );
      expect(read(container).reconnectCount, 1);
      expect(read(container).lastDisconnectedAt, isNotNull);
    });

    test('切断のたびに再接続カウントが増える', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await start(container);

      adapter.connectionState(streamKey, StreamConnectionState.disconnected);
      adapter.connectionState(streamKey, StreamConnectionState.disconnected);
      await settle();

      expect(read(container).reconnectCount, 2);
    });
  });

  group('ギャップ補完 (#781)', () {
    test('live になると since_id 起点で取り直し、窓に落ちた投稿がマージされる', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await start(container);

      // REST 完了〜WS live の窓に 103 / 104 が作られていた、という状況。
      adapter.catchUpPage = [_post('104'), _post('103'), _p102, _p101];
      adapter.connectionState(streamKey, StreamConnectionState.live);
      await settle();
      await settle();

      expect(
        read(container).posts.map((p) => p.id),
        ['104', '103', '102', '101'],
      );
    });

    test('⚠ 補完で取れた投稿のうち、既知（since 以下）のものは混ざらない', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await start(container);

      adapter.catchUpPage = [_p102, _p101];
      adapter.connectionState(streamKey, StreamConnectionState.live);
      await settle();
      await settle();

      expect(read(container).posts.map((p) => p.id), ['102', '101']);
    });
  });

  group('ライブ更新トグル (#854 / #904)', () {
    test('OFF にすると自分のキーだけ閉じ、インジケータが disabled になる', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await start(container);

      await container.read(streamingEnabledProvider.notifier).setEnabled(false);
      await settle();

      expect(adapter.disposedKeys, [streamKey]);
      expect(
        read(container).streamConnectionState,
        StreamConnectionState.disabled,
      );
    });

    test('ON に戻すと張り直され、再びライブが届く', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await start(container);

      await container.read(streamingEnabledProvider.notifier).setEnabled(false);
      await settle();
      await container.read(streamingEnabledProvider.notifier).setEnabled(true);
      await settle();

      adapter.emit(streamKey, _post('103'));
      await settle();

      expect(read(container).posts.map((p) => p.id), ['103', '102', '101']);
    });
  });
}

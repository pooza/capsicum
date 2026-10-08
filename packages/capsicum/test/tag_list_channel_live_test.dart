import 'dart:async';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/channel_provider.dart';
import 'package:capsicum/src/provider/hashtag_provider.dart';
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

/// タグ / リスト / チャンネルの TL がライブで更新されること (#1098・B-5)。
///
/// ⚠⚠ **デッキの主役はこの 3 種。**タグ TL を何本も並べるのが実況用途なので、
/// 「並べたのに動かない」を無くすのがこの回の目的。ここでは **provider 側**
/// （取り込み・未表示バッファ・接続状態・ギャップ補完・購読キーの分離）を見る。
/// 購読先の組み立て（channel / params / クエリ）は backends 側の
/// `timeline_streaming_tab_targets_test.dart` が持つ。
///
/// ⚠ **削除・ブロックが未表示バッファも刈ること**を各 TL で見る。ライブ購読が
/// 載った結果、これらの TL にも「新着 N 件」に溜まる投稿ができた。一覧からだけ
/// 消すと、**ブロックした相手の投稿が「新着 N 件」を開いた瞬間に現れる** (#887)。

class _FakeCapabilities extends Mock implements AdapterCapabilities {
  @override
  Set<TimelineType> get supportedTimelines => {TimelineType.home};
}

/// タグ / リスト / チャンネルを返し、購読を外から駆動できるアダプタ。
class _LiveAdapter extends Mock
    implements
        DecentralizedBackendAdapter,
        StreamSupport,
        HashtagSupport,
        ListSupport,
        ChannelSupport {
  _LiveAdapter(this.initialPosts);

  /// 初回 REST が返す投稿（新しい順）。
  final List<Post> initialPosts;

  /// 非 null のとき、2 回目以降の取得がこれを返す（ギャップ補完用）。
  List<Post>? catchUpPage;

  final Map<String, StreamController<Post>> controllers = {};
  final Map<String, void Function(StreamConnectionState)> connectionCallbacks =
      {};
  final List<String> disposedKeys = [];
  final List<TabType> streamedTabs = [];
  int fetchCalls = 0;

  @override
  AdapterCapabilities get capabilities => _FakeCapabilities();

  List<Post> _page() {
    fetchCalls++;
    return fetchCalls > 1 ? (catchUpPage ?? const <Post>[]) : initialPosts;
  }

  @override
  Future<List<Post>> getPostsByHashtag(
    String hashtag, {
    TimelineQuery? query,
    List<String>? all,
  }) async => _page();

  @override
  Future<List<Post>> getListTimeline(
    String listId, {
    TimelineQuery? query,
  }) async => _page();

  @override
  Future<List<Post>> getChannelTimeline(
    String channelId, {
    TimelineQuery? query,
  }) async => _page();

  @override
  Stream<Post> streamTimeline(
    String key,
    TabType tab, {
    void Function(Object error, StackTrace stack)? onParseError,
    void Function(Object error, StackTrace stack)? onStreamError,
    void Function()? onReconnectExhausted,
    void Function(StreamConnectionState state)? onConnectionState,
    void Function(int? closeCode, String? closeReason)? onDisconnect,
  }) {
    streamedTabs.add(tab);
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

  void emit(String key, Post post) => controllers[key]!.add(post);

  void connectionState(String key, StreamConnectionState state) =>
      connectionCallbacks[key]!(state);
}

const _meKey = AccountKey(
  type: BackendType.misskey,
  host: 'example.test',
  username: 'me',
);

Account _account(DecentralizedBackendAdapter adapter) => Account(
  key: _meKey,
  adapter: adapter,
  user: const User(id: 'me', username: 'me'),
  userSecret: const UserSecret(accessToken: 'token'),
);

Post _post(String id, {String author = 'u1'}) => Post(
  id: id,
  postedAt: DateTime.utc(2026, 9, 19),
  author: User(id: author, username: author),
  content: 'body',
);

final _p101 = _post('101');
final _p102 = _post('102');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
  });

  ProviderContainer makeContainer(_LiveAdapter adapter) {
    final container = ProviderContainer(
      overrides: [
        currentAccountProvider.overrideWith((ref) => _account(adapter)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// 画面が watch し続けている状態を作り、初回取得を待つ。
  Future<void> start(
    ProviderContainer container,
    ProviderListenable<AsyncValue<TimelineState>> provider,
    Future<TimelineState> future,
  ) async {
    container.listen(provider, (_, _) {}, fireImmediately: true);
    await future;
  }

  group('ハッシュタグ TL', () {
    const key = (account: _meKey, spec: 'precure_fun');
    final p = hashtagTimelineProvider(key);
    final streamKey = timelineContextKey(_meKey, HashtagTab('precure_fun'))!;

    Future<HashtagTimelineNotifier> startTag(
      ProviderContainer container,
    ) async {
      await start(container, p, container.read(p.future));
      return container.read(p.notifier);
    }

    test('⚠⚠ 新着がライブで入る（タブを切り替えなくても更新される）', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await startTag(container);

      expect(adapter.streamedTabs, [
        HashtagTab('precure_fun'),
      ], reason: 'タグのタブで購読する');

      adapter.emit(streamKey, _post('103'));
      await settle();

      expect(container.read(p).requireValue.posts.map((e) => e.id), [
        '103',
        '102',
        '101',
      ]);
    });

    test('スクロール中は未表示バッファへ退避し、「新着 N 件」で開く', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      final notifier = await startTag(container);

      notifier.setNearTop(false);
      adapter.emit(streamKey, _post('103'));
      await settle();

      expect(
        container.read(p).requireValue.posts.map((e) => e.id),
        ['102', '101'],
        reason: 'スクロール中に一覧を動かさない',
      );
      expect(container.read(p).requireValue.pendingCount, 1);

      notifier.flushPending();
      expect(container.read(p).requireValue.posts.map((e) => e.id), [
        '103',
        '102',
        '101',
      ]);
      expect(container.read(p).requireValue.pendingCount, 0);
    });

    test('⚠ 削除した投稿は未表示バッファからも消える (#887)', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      final notifier = await startTag(container);

      notifier.setNearTop(false);
      adapter.emit(streamKey, _post('103'));
      await settle();
      expect(container.read(p).requireValue.pendingCount, 1);

      notifier.removePost('103');

      expect(container.read(p).requireValue.pendingCount, 0);
      notifier.flushPending();
      expect(
        container.read(p).requireValue.posts.map((e) => e.id),
        ['102', '101'],
        reason: '⚠⚠ 一覧からだけ消すと「新着 N 件」を開いた瞬間に現れる',
      );
    });

    test('⚠⚠ ブロックした相手の投稿も未表示バッファから消える (#887)', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      final notifier = await startTag(container);

      notifier.setNearTop(false);
      adapter.emit(streamKey, _post('103', author: 'blocked'));
      await settle();
      expect(container.read(p).requireValue.pendingCount, 1);

      notifier.removePostsByUser('blocked');

      expect(container.read(p).requireValue.pendingCount, 0);
      notifier.flushPending();
      expect(container.read(p).requireValue.posts.map((e) => e.id), [
        '102',
        '101',
      ]);
    });

    test('接続状態が state に出る (#714)', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await startTag(container);

      adapter.connectionState(streamKey, StreamConnectionState.disconnected);
      await settle();

      expect(
        container.read(p).requireValue.streamConnectionState,
        StreamConnectionState.disconnected,
      );
    });

    test('⚠ live になると since_id 起点で取り直し、切断窓の投稿が埋まる (#781)', () async {
      final adapter = _LiveAdapter([_p102, _p101])
        ..catchUpPage = [_post('104'), _post('103'), _p102];
      final container = makeContainer(adapter);
      await startTag(container);

      adapter.connectionState(streamKey, StreamConnectionState.live);
      await settle();
      await settle();

      expect(
        container.read(p).requireValue.posts.map((e) => e.id),
        ['104', '103', '102', '101'],
        reason: '既知（since 以下）は混ざらない',
      );
    });

    test('⚠⚠ 別のタグのカラムは別の購読になる（片方が止まらない）', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await startTag(container);

      const other = (account: _meKey, spec: 'delmulin');
      final q = hashtagTimelineProvider(other);
      await start(container, q, container.read(q.future));
      final otherKey = timelineContextKey(_meKey, HashtagTab('delmulin'))!;

      adapter.emit(streamKey, _post('103'));
      adapter.emit(otherKey, _post('203'));
      await settle();

      expect(container.read(p).requireValue.posts.first.id, '103');
      expect(container.read(q).requireValue.posts.first.id, '203');
      expect(adapter.disposedKeys, isEmpty, reason: '2 本目で 1 本目を閉じない');
    });
  });

  group('リスト TL', () {
    const key = (account: _meKey, id: '42');
    final p = listTimelineProvider(key);
    final streamKey = timelineContextKey(_meKey, const ListTab(id: '42'))!;

    test('新着がライブで入る', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await start(container, p, container.read(p.future));

      expect(adapter.streamedTabs, [const ListTab(id: '42')]);
      adapter.emit(streamKey, _post('103'));
      await settle();

      expect(container.read(p).requireValue.posts.first.id, '103');
    });

    test('⚠ ブロックした相手の投稿は未表示バッファからも消える (#887)', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await start(container, p, container.read(p.future));
      final notifier = container.read(p.notifier);

      notifier.setNearTop(false);
      adapter.emit(streamKey, _post('103', author: 'blocked'));
      await settle();
      notifier.removePostsByUser('blocked');

      expect(container.read(p).requireValue.pendingCount, 0);
    });
  });

  group('チャンネル TL', () {
    const key = (account: _meKey, id: 'abc');
    final p = channelTimelineProvider(key);
    final streamKey = timelineContextKey(_meKey, const ChannelTab(id: 'abc'))!;

    test('新着がライブで入る', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await start(container, p, container.read(p.future));

      expect(adapter.streamedTabs, [const ChannelTab(id: 'abc')]);
      adapter.emit(streamKey, _post('103'));
      await settle();

      expect(container.read(p).requireValue.posts.first.id, '103');
    });

    test('ライブ更新 OFF では購読を張らない (#854)', () async {
      final adapter = _LiveAdapter([_p102, _p101]);
      final container = makeContainer(adapter);
      await container.read(streamingEnabledProvider.notifier).setEnabled(false);
      await start(container, p, container.read(p.future));

      expect(adapter.streamedTabs, isEmpty);
      expect(
        container.read(p).requireValue.streamConnectionState,
        StreamConnectionState.disabled,
      );
    });
  });
}

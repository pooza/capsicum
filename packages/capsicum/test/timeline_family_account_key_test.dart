import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/channel_provider.dart';
import 'package:capsicum/src/provider/hashtag_provider.dart';
import 'package:capsicum/src/provider/list_provider.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1088: ハッシュタグ / リスト / チャンネル TL の family キーにアカウントを含める。
///
/// デッキ（#720）で 2 アカウントの**同じタグ**を並べたとき、キーがタグだけだと
/// **同じインスタンスを共有して、片方のサーバーの投稿がもう片方に混ざる**
/// （設計書 B-4）。キーにアカウントを含めたうえで、**キーのアカウントのアダプタ
/// 以外では取得しない**ことを固定する。
class _Adapter extends Mock
    implements
        DecentralizedBackendAdapter,
        HashtagSupport,
        ListSupport,
        ChannelSupport {
  _Adapter(this.server);

  /// 返す投稿の id に刻むサーバー名。どのアダプタで取ったかを一覧から見分ける。
  final String server;
  int fetchCount = 0;

  @override
  AdapterCapabilities get capabilities => _FakeCapabilities();

  List<Post> _page(String what, TimelineQuery? query) {
    fetchCount++;
    if (query?.maxId != null) return const [];
    return [
      Post(
        id: '$server:$what',
        postedAt: DateTime.utc(2026, 9, 17),
        author: const User(id: 'u1', username: 'someone'),
        content: 'body',
      ),
    ];
  }

  @override
  Future<List<Post>> getPostsByHashtag(
    String hashtag, {
    TimelineQuery? query,
    List<String>? all,
  }) async => _page('tag:$hashtag', query);

  @override
  Future<List<Post>> getListTimeline(
    String listId, {
    TimelineQuery? query,
  }) async => _page('list:$listId', query);

  @override
  Future<List<Post>> getChannelTimeline(
    String channelId, {
    TimelineQuery? query,
  }) async => _page('channel:$channelId', query);
}

class _FakeCapabilities extends Mock implements AdapterCapabilities {}

const _a = AccountKey(
  type: BackendType.misskey,
  host: 'a.example',
  username: 'me',
);

const _b = AccountKey(
  type: BackendType.misskey,
  host: 'b.example',
  username: 'me',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Adapter adapterA;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    adapterA = _Adapter('a');
  });

  /// 現在のアカウントは A。B のカラムは「フェーズ 2 でスコープ上書きされる前」の
  /// 形（＝ current と食い違ったキー）で置く。
  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        currentAccountProvider.overrideWith(
          (ref) => Account(
            key: _a,
            adapter: adapterA,
            user: const User(id: 'u1', username: 'me'),
            userSecret: const UserSecret(accessToken: 'token'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  void keepAlive(ProviderContainer c, ProviderListenable<Object?> p) =>
      c.listen(p, (_, _) {}, fireImmediately: true);

  test('ハッシュタグ: 別アカウント・同じタグは別インスタンスで、他人のサーバーの投稿を持たない', () async {
    final container = makeContainer();
    final onA = hashtagTimelineProvider((account: _a, spec: 'delmulin'));
    final onB = hashtagTimelineProvider((account: _b, spec: 'delmulin'));
    keepAlive(container, onA);
    keepAlive(container, onB);

    final a = await container.read(onA.future);
    final b = await container.read(onB.future);

    expect(
      identical(container.read(onA.notifier), container.read(onB.notifier)),
      isFalse,
    );
    expect(a.posts.map((p) => p.id), ['a:tag:delmulin']);
    expect(b.posts, isEmpty, reason: 'B のカラムに A のサーバーの投稿を出さない（B-4）');
    expect(a.contextKey, isNot(b.contextKey));
    expect(adapterA.fetchCount, 1, reason: 'A のアダプタを引いたのは A のカラムだけ');
  });

  test('リスト: 別アカウント・同じ id は別インスタンスで、他人のサーバーの投稿を持たない', () async {
    final container = makeContainer();
    final ListTimelineKey keyA = (account: _a, id: 'l1');
    final ListTimelineKey keyB = (account: _b, id: 'l1');
    keepAlive(container, listTimelineProvider(keyA));
    keepAlive(container, listTimelineProvider(keyB));

    final a = await container.read(listTimelineProvider(keyA).future);
    final b = await container.read(listTimelineProvider(keyB).future);

    expect(
      identical(
        container.read(listTimelineProvider(keyA).notifier),
        container.read(listTimelineProvider(keyB).notifier),
      ),
      isFalse,
    );
    expect(a.posts.map((p) => p.id), ['a:list:l1']);
    expect(b.posts, isEmpty);
  });

  test('チャンネル: 別アカウント・同じ id は別インスタンスで、他人のサーバーの投稿を持たない', () async {
    final container = makeContainer();
    final ChannelTimelineKey keyA = (account: _a, id: 'ch1');
    final ChannelTimelineKey keyB = (account: _b, id: 'ch1');
    keepAlive(container, channelTimelineProvider(keyA));
    keepAlive(container, channelTimelineProvider(keyB));

    final a = await container.read(channelTimelineProvider(keyA).future);
    final b = await container.read(channelTimelineProvider(keyB).future);

    expect(
      identical(
        container.read(channelTimelineProvider(keyA).notifier),
        container.read(channelTimelineProvider(keyB).notifier),
      ),
      isFalse,
    );
    expect(a.posts.map((p) => p.id), ['a:channel:ch1']);
    expect(b.posts, isEmpty);
  });
}

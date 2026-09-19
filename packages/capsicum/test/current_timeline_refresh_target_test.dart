import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/tab_selection_provider.dart';
import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1157: メニュー / `Ctrl+R` が「いま見ている TL」を取り直すこと。
///
/// ⚠⚠ **チャンネルタブが抜けていた。**チャンネルは `ChannelTimelineView` が
/// 描いており本線の `RefreshIndicator` がマウントされないので、更新は必ず
/// フォールバック経路へ落ちる。そこがハッシュタグ / リスト / 本線の 3 分岐しか
/// 持っておらず、**画面は変わらないのに裏で本線 TL を取り直していた。**
/// 失敗にもならないので気づけない。

class _Capabilities extends Mock implements AdapterCapabilities {
  @override
  Set<TimelineType> get supportedTimelines => {TimelineType.home};
}

/// どの API が呼ばれたかだけを数えるアダプタ。
class _Adapter extends Mock
    implements
        DecentralizedBackendAdapter,
        ChannelSupport,
        HashtagSupport,
        ListSupport {
  int homeCalls = 0;
  int channelCalls = 0;
  int hashtagCalls = 0;
  int listCalls = 0;

  @override
  AdapterCapabilities get capabilities => _Capabilities();

  @override
  Future<TimelineResponse> getTimeline(
    TimelineType type, {
    TimelineQuery? query,
  }) async {
    homeCalls++;
    return const TimelineResponse(posts: [], rawCount: 0, rawLastId: null);
  }

  @override
  Future<List<Post>> getChannelTimeline(
    String channelId, {
    TimelineQuery? query,
  }) async {
    channelCalls++;
    return const [];
  }

  @override
  Future<List<Post>> getPostsByHashtag(
    String hashtag, {
    TimelineQuery? query,
    List<String>? all,
  }) async {
    hashtagCalls++;
    return const [];
  }

  @override
  Future<List<Post>> getListTimeline(
    String listId, {
    TimelineQuery? query,
  }) async {
    listCalls++;
    return const [];
  }

  @override
  Future<List<PostList>> getLists() async => const [
    PostList(id: '42', title: 'ダイ大'),
  ];
}

const _me = AccountKey(
  type: BackendType.misskey,
  host: 'misskey.example',
  username: 'me',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(ProviderContainer, _Adapter)> makeContainer(TabType tab) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    final adapter = _Adapter();
    final container = ProviderContainer(
      overrides: [
        currentAccountProvider.overrideWith(
          (ref) => Account(
            key: _me,
            adapter: adapter,
            user: const User(id: 'me', username: 'me'),
            userSecret: const UserSecret(accessToken: 'token'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedTabProvider.notifier).state = tab;
    return (container, adapter);
  }

  /// メニュー / Ctrl+R と同じことをする。
  Future<void> refreshCurrent(ProviderContainer container) async {
    final target = container.read(currentTimelineRefreshTargetProvider);
    await container.refresh(target);
  }

  test('⚠⚠ チャンネルタブならチャンネル TL を取り直す（本線に化けない）', () async {
    final (container, adapter) = await makeContainer(
      const ChannelTab(id: 'abc'),
    );
    await refreshCurrent(container);

    expect(adapter.channelCalls, greaterThan(0));
    expect(adapter.homeCalls, 0, reason: '⚠ 画面は変わらないのに裏で本線 TL を取り直していた');
  });

  test('ハッシュタグタブならハッシュタグ TL', () async {
    final (container, adapter) = await makeContainer(HashtagTab('precure_fun'));
    await refreshCurrent(container);

    expect(adapter.hashtagCalls, greaterThan(0));
    expect(adapter.homeCalls, 0);
  });

  test('本線のタブなら本線 TL', () async {
    final (container, adapter) = await makeContainer(
      const TimelineTab(TimelineType.home),
    );
    await refreshCurrent(container);

    expect(adapter.homeCalls, greaterThan(0));
    expect(adapter.channelCalls, 0);
  });
}

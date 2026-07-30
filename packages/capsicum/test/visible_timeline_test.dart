import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/hashtag_provider.dart';
import 'package:capsicum/src/provider/list_provider.dart';
import 'package:capsicum/src/ui/util/visible_timeline.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';

/// #887: 削除 / 再投稿の結果が「いま表示している TL」に反映されること。
///
/// これまで remove / insert はホーム TL の notifier にしか無く、ハッシュタグ
/// タブ・リストタブを見ているときは画面が変わらないまま（タブを切り替えて
/// 再取得が走ってようやく反映される）だった。ハッシュタグ / リストの各
/// notifier が同じ操作を持つこと、およびハッシュタグ TL への楽観挿入が
/// 「そのタグを持つ投稿」だけに限られることを担保する。
class _FakeAdapter extends Mock
    implements DecentralizedBackendAdapter, HashtagSupport, ListSupport {
  final List<Post> posts;

  _FakeAdapter(this.posts);

  @override
  Future<List<Post>> getPostsByHashtag(
    String hashtag, {
    TimelineQuery? query,
    List<String>? all,
  }) async => query?.maxId == null ? posts : const [];

  @override
  Future<List<Post>> getListTimeline(String id, {TimelineQuery? query}) async =>
      query?.maxId == null ? posts : const [];
}

Post _post(String id, {String content = 'hello', bool isHtml = false}) => Post(
  id: id,
  postedAt: DateTime.utc(2026, 7, 31),
  author: const User(id: 'u1', username: 'me'),
  content: content,
  isHtml: isHtml,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> makeContainer(List<Post> posts) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    return ProviderContainer(
      overrides: [
        currentAdapterProvider.overrideWith((ref) => _FakeAdapter(posts)),
      ],
    );
  }

  group('ハッシュタグ TL', () {
    test('removePost で削除した投稿が一覧から消える', () async {
      final container = await makeContainer([_post('3'), _post('2')]);
      addTearDown(container.dispose);

      await container.read(hashtagTimelineProvider('capsicum').future);
      container
          .read(hashtagTimelineProvider('capsicum').notifier)
          .removePost('2');

      final state = container.read(hashtagTimelineProvider('capsicum')).value!;
      expect(state.posts.map((p) => p.id), ['3']);
    });

    test('insertOwnPost で自分の投稿が先頭に出る（重複は無視）', () async {
      final container = await makeContainer([_post('3')]);
      addTearDown(container.dispose);

      await container.read(hashtagTimelineProvider('capsicum').future);
      final notifier =
          container.read(hashtagTimelineProvider('capsicum').notifier)
            ..insertOwnPost(_post('9'))
            ..insertOwnPost(_post('9'));

      expect(notifier.state.value!.posts.map((p) => p.id), ['9', '3']);
    });
  });

  group('リスト TL', () {
    test('removePost で削除した投稿が一覧から消える', () async {
      final container = await makeContainer([_post('3'), _post('2')]);
      addTearDown(container.dispose);

      await container.read(listTimelineProvider('l1').future);
      container.read(listTimelineProvider('l1').notifier).removePost('3');

      final state = container.read(listTimelineProvider('l1')).value!;
      expect(state.posts.map((p) => p.id), ['2']);
    });

    test('updatePost で内容が差し替わる', () async {
      final container = await makeContainer([_post('3', content: 'old')]);
      addTearDown(container.dispose);

      await container.read(listTimelineProvider('l1').future);
      container
          .read(listTimelineProvider('l1').notifier)
          .updatePost(_post('3', content: 'new'));

      final state = container.read(listTimelineProvider('l1')).value!;
      expect(state.posts.single.content, 'new');
    });
  });

  group('ハッシュタグ TL への楽観挿入の可否判定', () {
    test('MFM 本文のタグに一致する', () {
      expect(
        postMatchesHashtagSpec(
          _post('1', content: '本文\n\n#capsicum'),
          'capsicum',
        ),
        isTrue,
      );
    });

    test('HTML 本文（Mastodon）のタグに一致する', () {
      final post = _post(
        '1',
        content:
            '<p>本文 <a href="https://example.com/tags/capsicum" class="mention hashtag">#<span>capsicum</span></a></p>',
        isHtml: true,
      );
      expect(postMatchesHashtagSpec(post, 'capsicum'), isTrue);
    });

    test('タグ名の大小は無視する', () {
      expect(
        postMatchesHashtagSpec(_post('1', content: '#Capsicum'), 'capsicum'),
        isTrue,
      );
    });

    test('AND 指定はすべてのタグを含むときだけ一致する', () {
      final both = _post('1', content: '#delmulin #capsicum');
      final one = _post('2', content: '#delmulin');
      expect(postMatchesHashtagSpec(both, 'delmulin+capsicum'), isTrue);
      expect(postMatchesHashtagSpec(one, 'delmulin+capsicum'), isFalse);
    });

    test('タグを持たない投稿は一致しない（幻の投稿を作らない）', () {
      expect(
        postMatchesHashtagSpec(_post('1', content: 'ただの本文'), 'capsicum'),
        isFalse,
      );
    });
  });
}

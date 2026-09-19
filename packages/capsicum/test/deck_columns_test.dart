import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/deck_column.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1091: デッキのカラム列のモデルと永続化。
const _me = AccountKey(
  type: BackendType.misskey,
  host: 'misskey.example',
  username: 'me',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TabType.toIdentityKey', () {
    test('リスト / チャンネルは表示名を落とす', () {
      expect(const ListTab(id: 'l1', name: '実況').toIdentityKey(), 'list:l1');
      expect(
        const ChannelTab(id: 'c1', name: '#general').toIdentityKey(),
        'channel:c1',
      );
      // 前提: toKey は表示名を含む（だから同一性に使えない）。
      expect(const ListTab(id: 'l1', name: '実況').toKey(), 'list:l1:実況');
    });

    test('表示名を持たない種別は toKey と同じ', () {
      for (final tab in const <TabType>[
        TimelineTab(TimelineType.home),
        HashtagTab('delmulin+capsicum'),
        NotificationsTab(),
        AnnouncementsTab(),
        MessagesTab(),
      ]) {
        expect(tab.toIdentityKey(), tab.toKey());
      }
    });

    test('fromKey で読み戻せ、元と == になる', () {
      for (final tab in const <TabType>[
        TimelineTab(TimelineType.local),
        HashtagTab('precure_fun'),
        ListTab(id: 'l1', name: '実況'),
        ChannelTab(id: 'c1', name: '#general'),
        NotificationsTab(),
        // #1148: カラムから開いたスレッド・プロフィール
        PostThreadTab('9zx8abc'),
        ProfileTab('u1'),
        // #1150: カラムから開いた一覧・画面
        UserListTab(UserListKind.followers, 'u1'),
        UserListTab(UserListKind.rebloggedBy, 'p1'),
        // ⚠ 絵文字は `:` を含む
        UserListTab(UserListKind.reactedBy, 'p1', reaction: ':blobcat@.:'),
        QuotesTab('p1'),
        AchievementsTab('u1'),
        CollectionsTab('a1', CollectionsMode.own),
        CollectionsTab('a1', CollectionsMode.included),
        CollectionTab('c1'),
        GalleryPostTab('g1'),
        FlashTab('f1'),
        ChatUserTab('u1'),
      ]) {
        expect(TabType.fromKey(tab.toIdentityKey()), tab);
      }
    });

    test('スレッドとプロフィールは id で区別する (#1148)', () {
      expect(const PostThreadTab('a'), isNot(const PostThreadTab('b')));
      expect(const ProfileTab('a'), isNot(const ProfileTab('b')));
      // 同じ id でも種別が違えば別物（投稿 id とユーザー id は別の空間）。
      expect(const PostThreadTab('a'), isNot(const ProfileTab('a')));
      expect(TabType.fromKey('thread:'), isNull);
      expect(TabType.fromKey('profile:'), isNull);
    });

    test('一覧の種別は、種類・対象・絵文字まで区別し、壊れたキーは読まない (#1150)', () {
      expect(
        const UserListTab(UserListKind.followers, 'u1'),
        isNot(const UserListTab(UserListKind.following, 'u1')),
      );
      expect(
        const UserListTab(UserListKind.reactedBy, 'p1', reaction: ':a:'),
        isNot(const UserListTab(UserListKind.reactedBy, 'p1', reaction: ':b:')),
      );
      expect(
        const CollectionsTab('a1', CollectionsMode.own),
        isNot(const CollectionsTab('a1', CollectionsMode.list)),
      );
      for (final key in [
        'users:unknown:u1', // 未知の種類
        'users:followers:', // 対象が空
        'users:followers', // 区切りが無い
        'collections:unknown:a1',
        'collections:own:',
      ]) {
        expect(TabType.fromKey(key), isNull, reason: key);
      }
      // ⚠ 絵文字の区切りが空なら絵文字なしとして読む（`users:x:p1:` を別物にしない）。
      expect(
        TabType.fromKey('users:reactedBy:p1:'),
        const UserListTab(UserListKind.reactedBy, 'p1'),
      );
    });

    test('⚠ デッキ専用の種別はすべて DeckOnlyTab（タブ UI の switch が 1 つで受ける）', () {
      for (final tab in const <TabType>[
        PostThreadTab('p'),
        ProfileTab('u'),
        UserListTab(UserListKind.following, 'u'),
        QuotesTab('p'),
        AchievementsTab('u'),
        CollectionsTab('a', CollectionsMode.list),
        CollectionTab('c'),
        GalleryPostTab('g'),
        FlashTab('f'),
        ChatUserTab('u'),
      ]) {
        expect(tab, isA<DeckOnlyTab>(), reason: tab.toKey());
      }
      for (final tab in const <TabType>[
        TimelineTab(TimelineType.home),
        HashtagTab('t'),
        ListTab(id: 'l'),
        ChannelTab(id: 'c'),
      ]) {
        expect(tab, isNot(isA<DeckOnlyTab>()), reason: tab.toKey());
      }
    });
  });

  group('DeckColumn の書式', () {
    test('保存した行を読み戻すと、id・アカウント・種別が一致する', () {
      const column = DeckColumn(
        id: 'abc',
        account: _me,
        tab: HashtagTab('delmulin'),
      );
      final restored = DeckColumn.deserialize(column.serialize())!;

      expect(
        column.serialize(),
        'abc|misskey://me@misskey.example|hashtag:delmulin',
      );
      expect(restored.id, 'abc');
      expect(restored.account, _me);
      expect(restored.tab, const HashtagTab('delmulin'));
    });

    test('⚠⚠ サーバー側でリスト名を変えても、同じカラムと判定される', () {
      const before = DeckColumn(
        id: 'abc',
        account: _me,
        tab: ListTab(id: 'l1', name: '旧い名前'),
      );
      final saved = before.serialize();
      const renamed = DeckColumn(
        id: 'abc',
        account: _me,
        tab: ListTab(id: 'l1', name: '新しい名前'),
      );

      expect(saved, renamed.serialize(), reason: '保存される行が表示名で変わらない');
      expect(DeckColumn.deserialize(saved)!.contentKey, renamed.contentKey);
      expect(DeckColumn.deserialize(saved)!.tab, renamed.tab);
    });

    test('カラムの中身のキーは、その TL の contextKey と同じ文字列（決定済み事項 4-3）', () {
      for (final tab in const <TabType>[
        TimelineTab(TimelineType.home),
        HashtagTab('delmulin+capsicum'),
        ListTab(id: 'l1', name: '実況'),
      ]) {
        final column = DeckColumn(id: 'x', account: _me, tab: tab);
        expect(column.contentKey, timelineContextKey(_me, tab));
      }
      // リスト名が変わっても contextKey は変わらない（toKey を使っていない）。
      expect(
        timelineContextKey(_me, const ListTab(id: 'l1', name: '旧')),
        timelineContextKey(_me, const ListTab(id: 'l1', name: '新')),
      );
    });

    test('チャンネル名の変更も同じ', () {
      const before = DeckColumn(
        id: 'x',
        account: _me,
        tab: ChannelTab(id: 'c1', name: '旧'),
      );
      const after = DeckColumn(
        id: 'x',
        account: _me,
        tab: ChannelTab(id: 'c1', name: '新'),
      );
      expect(before.serialize(), after.serialize());
    });

    test('読めない行は null を返し、落ちない', () {
      for (final line in [
        '',
        'no-separator',
        'abc|misskey://me@misskey.example', // 種別が無い
        '|misskey://me@misskey.example|hashtag:a', // id が空
        'abc|unknown://me@misskey.example|hashtag:a', // 未知のバックエンド
        'abc|misskey://%zz|hashtag:a', // 壊れた URI
        'abc|misskey://misskey.example|hashtag:a', // ユーザー名が無い
        'abc|misskey://me@misskey.example|future_tab:x', // 未知の種別
        'abc|misskey://me@misskey.example|timeline:no_such_type',
      ]) {
        expect(DeckColumn.deserialize(line), isNull, reason: line);
      }
    });
  });

  group('deckColumnsProvider', () {
    Future<ProviderContainer> makeContainer([
      Map<String, Object> initial = const {},
    ]) async {
      SharedPreferences.setMockInitialValues(initial);
      initSharedPreferencesCache(await SharedPreferences.getInstance());
      final container = ProviderContainer();
      addTearDown(container.dispose);
      return container;
    }

    test('何も保存されていなければ空', () async {
      final container = await makeContainer();
      expect(container.read(deckColumnsProvider), isEmpty);
    });

    test('同じ中身を重複して足せ、それぞれ別の id を持つ', () async {
      final container = await makeContainer();
      final notifier = container.read(deckColumnsProvider.notifier);

      final a = await notifier.add(_me, const HashtagTab('delmulin'));
      final b = await notifier.add(_me, const HashtagTab('delmulin'));

      expect(container.read(deckColumnsProvider), hasLength(2));
      expect(a.id, isNot(b.id));
      expect(a.contentKey, b.contentKey);
    });

    test('並べ替え・削除は id で指し、並び順ごと保存・復元される', () async {
      final container = await makeContainer();
      final notifier = container.read(deckColumnsProvider.notifier);
      final home = await notifier.add(
        _me,
        const TimelineTab(TimelineType.home),
      );
      final tag1 = await notifier.add(_me, const HashtagTab('delmulin'));
      final tag2 = await notifier.add(_me, const HashtagTab('delmulin'));
      final list = await notifier.add(_me, const ListTab(id: 'l1', name: '実況'));

      // 重複の後ろ側（tag2）だけを先頭へ。中身では指せないことの確認。
      await notifier.move(tag2.id, 0);
      await notifier.remove(home.id);

      final expectedIds = [tag2.id, tag1.id, list.id];
      expect(container.read(deckColumnsProvider).map((c) => c.id), expectedIds);

      // 別のコンテナ（＝再起動）で読み直す。
      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      final restored = restarted.read(deckColumnsProvider);
      expect(restored.map((c) => c.id), expectedIds);
      expect(restored.map((c) => c.tab), [
        const HashtagTab('delmulin'),
        const HashtagTab('delmulin'),
        const ListTab(id: 'l1'),
      ]);
      expect(restored.every((c) => c.account == _me), isTrue);
    });

    test('insertAfter は元のカラムの右隣に足す (#1148)', () async {
      final container = await makeContainer();
      final notifier = container.read(deckColumnsProvider.notifier);
      final a = await notifier.add(_me, const HashtagTab('a'));
      final b = await notifier.add(_me, const HashtagTab('b'));

      final opened = await notifier.insertAfter(
        a.id,
        _me,
        const PostThreadTab('p1'),
      );
      expect(container.read(deckColumnsProvider).map((c) => c.id), [
        a.id,
        opened.id,
        b.id,
      ]);

      // 同じ元から続けて開くと、元の右隣（先に開いたものの左）に入る。
      final again = await notifier.insertAfter(
        a.id,
        _me,
        const ProfileTab('u1'),
      );
      expect(container.read(deckColumnsProvider).map((c) => c.id), [
        a.id,
        again.id,
        opened.id,
        b.id,
      ]);
    });

    test('insertAfter の元が列に無ければ末尾に足す', () async {
      final container = await makeContainer();
      final notifier = container.read(deckColumnsProvider.notifier);
      final a = await notifier.add(_me, const HashtagTab('a'));

      final opened = await notifier.insertAfter(
        'gone',
        _me,
        const PostThreadTab('p1'),
      );
      expect(container.read(deckColumnsProvider).map((c) => c.id), [
        a.id,
        opened.id,
      ]);
    });

    test('⚠ 開いた時点の中身（seed）は保存しない。読み戻すと id だけ残る', () async {
      final container = await makeContainer();
      final notifier = container.read(deckColumnsProvider.notifier);
      final a = await notifier.add(_me, const HashtagTab('a'));
      final seed = Object();
      final opened = await notifier.insertAfter(
        a.id,
        _me,
        const PostThreadTab('p1'),
        seed: seed,
      );
      expect(container.read(deckColumnsProvider).last.seed, same(seed));

      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      final restored = restarted.read(deckColumnsProvider).last;
      expect(restored.id, opened.id);
      expect(restored.tab, const PostThreadTab('p1'));
      expect(restored.seed, isNull);
    });

    test('move の挿入位置が範囲外なら端へ丸める', () async {
      final container = await makeContainer();
      final notifier = container.read(deckColumnsProvider.notifier);
      final a = await notifier.add(_me, const HashtagTab('a'));
      final b = await notifier.add(_me, const HashtagTab('b'));

      await notifier.move(a.id, 99);
      expect(container.read(deckColumnsProvider).map((c) => c.id), [
        b.id,
        a.id,
      ]);
      await notifier.move(a.id, -5);
      expect(container.read(deckColumnsProvider).map((c) => c.id), [
        a.id,
        b.id,
      ]);
    });

    test('読めない行と重複 id の行は黙って捨て、残りは順序どおり読む', () async {
      final container = await makeContainer({
        'deck_columns': <String>[
          'a|misskey://me@misskey.example|hashtag:one',
          'garbage',
          'b|unknown://me@misskey.example|hashtag:two',
          'c|misskey://me@misskey.example|future_tab:x',
          'd|misskey://me@misskey.example|timeline:home',
          'a|misskey://me@misskey.example|hashtag:dup', // id 重複
        ],
      });

      final columns = container.read(deckColumnsProvider);
      expect(columns.map((c) => c.id), ['a', 'd']);
      expect(columns.first.tab, const HashtagTab('one'));
    });
  });
}

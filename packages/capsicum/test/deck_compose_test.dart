import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/deck_column.dart';
import 'package:capsicum/src/provider/channel_provider.dart';
import 'package:capsicum/src/ui/util/deck_compose.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1172: カラムから新規投稿を開くときの初期状態（`docs/deck-ui-plan.md`
/// 決定済み事項 10）。
///
/// ⚠⚠ **見出しの投稿ボタンと簡易投稿バーは同じ関数を通す。**別々に書くと
/// 「バーから送るとタグが付くのに、ボタンから開くと付かない」の再発になる
/// （タブ UI で実際に起きていた）。

class _Capabilities extends Mock implements AdapterCapabilities {
  @override
  Set<TimelineType> get supportedTimelines => {TimelineType.home};
}

/// チャンネルを持たないバックエンド（Mastodon 相当）。
class _PlainAdapter extends Mock implements DecentralizedBackendAdapter {
  @override
  AdapterCapabilities get capabilities => _Capabilities();
}

/// チャンネルを持つバックエンド（Misskey 相当）。
class _ChannelAdapter extends Mock
    implements DecentralizedBackendAdapter, ChannelSupport {
  @override
  AdapterCapabilities get capabilities => _Capabilities();
}

const _me = AccountKey(
  type: BackendType.misskey,
  host: 'misskey.example',
  username: 'me',
);

DeckColumn _column(TabType tab) => DeckColumn(id: 'c1', account: _me, tab: tab);

void main() {
  /// [tab] のカラムから `deckComposeExtra` が返すものを、ウィジェットの `ref` で取る。
  Future<Map<String, dynamic>> extraFor(
    WidgetTester tester,
    TabType tab, {
    List<Channel> channels = const [],
  }) async {
    late Map<String, dynamic> extra;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          followedChannelsProvider.overrideWith((ref) async => channels),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              // ⚠ FutureProvider を解決させるため、先に watch しておく。
              ref.watch(followedChannelsProvider);
              extra = deckComposeExtra(ref, _column(tab));
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return extra;
  }

  group('deckComposeExtra', () {
    testWidgets('ふつうの TL・通知・スレッドは空', (tester) async {
      for (final tab in const <TabType>[
        TimelineTab(TimelineType.home),
        NotificationsTab(),
        AnnouncementsTab(),
        PostThreadTab('9zx8abc'),
        ProfileTab('u1'),
        ListTab(id: 'l1', name: '実況'),
      ]) {
        expect(await extraFor(tester, tab), isEmpty, reason: tab.toKey());
      }
    });

    testWidgets('ハッシュタグのカラムはタグを渡す', (tester) async {
      final extra = await extraFor(tester, const HashtagTab('precure_fun'));

      expect(extra['hashtags'], ['precure_fun']);
    });

    testWidgets('⚠ AND 指定は全部のタグを渡す', (tester) async {
      final spec = hashtagSpecFromTags(['delmulin', 'capsicum']);
      final extra = await extraFor(tester, HashtagTab(spec));

      expect(extra['hashtags'], ['delmulin', 'capsicum']);
    });

    testWidgets('⚠⚠ spec のままでは渡さない（`+` を含むタグ・#1159）', (tester) async {
      final extra = await extraFor(
        tester,
        HashtagTab(hashtagSpecFromTag('c++')),
      );

      expect(extra['hashtags'], [
        'c++',
      ], reason: '⚠ spec（c%2B%2B）をそのまま渡すと、実在しないタグで投稿してしまう');
    });

    testWidgets('⚠⚠ チャンネルのカラムは channelId を必ず渡す', (tester) async {
      final extra = await extraFor(tester, const ChannelTab(id: 'ch1'));

      expect(extra['channelId'], 'ch1', reason: '⚠ 落とすとチャンネルの外へ投稿が出る');
    });

    testWidgets('チャンネル名はタブが持っていればそれを使う', (tester) async {
      final extra = await extraFor(
        tester,
        const ChannelTab(id: 'ch1', name: '#実況'),
      );

      expect(extra['channelName'], '#実況');
    });

    testWidgets('⚠ 読み戻したカラム（name が null）はフォロー中チャンネルから引く', (tester) async {
      final extra = await extraFor(
        tester,
        const ChannelTab(id: 'ch1'),
        channels: [_channel('ch1', '#実況'), _channel('ch2', '#雑談')],
      );

      expect(extra['channelId'], 'ch1');
      expect(
        extra['channelName'],
        '#実況',
        reason: '⚠ 保存キーは toIdentityKey なので表示名を持たない（決定済み事項 4-1）',
      );
    });

    testWidgets('一覧に無いチャンネルでも channelId は落とさない', (tester) async {
      final extra = await extraFor(
        tester,
        const ChannelTab(id: 'ch9'),
        channels: [_channel('ch1', '#実況')],
      );

      expect(extra['channelId'], 'ch9');
      expect(extra['channelName'], isNull);
    });
  });

  group('canComposeFromColumn', () {
    test('アダプタが無ければ出さない', () {
      expect(
        canComposeFromColumn(const TimelineTab(TimelineType.home), null),
        isFalse,
      );
    });

    test('ふつうのカラムは出す', () {
      final adapter = _PlainAdapter();
      for (final tab in const <TabType>[
        TimelineTab(TimelineType.home),
        HashtagTab('precure_fun'),
        ListTab(id: 'l1'),
        NotificationsTab(),
        AnnouncementsTab(),
        PostThreadTab('9zx8abc'),
        ProfileTab('u1'),
      ]) {
        expect(canComposeFromColumn(tab, adapter), isTrue, reason: tab.toKey());
      }
    });

    test('⚠ メッセージは出さない（カラムとして表示もできない）', () {
      expect(
        canComposeFromColumn(const MessagesTab(), _PlainAdapter()),
        isFalse,
      );
    });

    test('⚠⚠ チャンネルは ChannelSupport が要る', () {
      expect(
        canComposeFromColumn(const ChannelTab(id: 'ch1'), _PlainAdapter()),
        isFalse,
        reason: '⚠ channelId を渡せないと、チャンネルの外へ投稿が出る',
      );
      expect(
        canComposeFromColumn(const ChannelTab(id: 'ch1'), _ChannelAdapter()),
        isTrue,
      );
    });
  });
}

Channel _channel(String id, String name) => Channel(id: id, name: name);

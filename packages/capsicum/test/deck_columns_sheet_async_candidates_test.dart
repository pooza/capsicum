import 'dart:async';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/widget/deck_columns_sheet.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1155 / #1156: カラム候補のリスト / チャンネルの出し方。
///
/// ⚠⚠ **実機検証で実際に詰まった**（[#1098](https://github.com/pooza/capsicum/issues/1098)
/// の A5 / A6）。読み込みが終わっていないだけなのに「候補にリストが無い」と
/// 見え、**機能に到達できなかった**。⚠ 読み込み中 / 0 件 / 失敗が**同じ見え方**
/// だったのが原因なので、**3 つが書き分けられていること**をここで固定する。
///
/// ⚠ チャンネル側は加えて「**アプリを再起動するまで更新されない**」問題があった
/// （`followedChannelsProvider` は `visibleTabsProvider` が常時 watch していて
/// 破棄されない）。**シートを開くたびに取り直すこと**も固定する。

class _Capabilities extends Mock implements AdapterCapabilities {
  @override
  Set<TimelineType> get supportedTimelines => {
    TimelineType.home,
    TimelineType.local,
  };
}

class _Adapter extends Mock
    implements DecentralizedBackendAdapter, ListSupport, ChannelSupport {
  _Adapter({this.lists, this.channels});

  /// 非 null なら `getLists` がこれを返す。null なら永久に未完了（読み込み中）。
  final List<PostList>? lists;
  final List<Channel>? channels;

  /// 次の `getLists` を失敗させる。
  bool failLists = false;

  int listCalls = 0;
  int channelCalls = 0;

  final _never = Completer<Never>();

  @override
  AdapterCapabilities get capabilities => _Capabilities();

  @override
  Future<List<PostList>> getLists() {
    listCalls++;
    if (failLists) return Future.error(StateError('boom'));
    final value = lists;
    return value == null ? _never.future : Future.value(value);
  }

  @override
  Future<List<Channel>> getFollowedChannels() {
    channelCalls++;
    final value = channels;
    return value == null ? _never.future : Future.value(value);
  }
}

const _me = AccountKey(
  type: BackendType.misskey,
  host: 'misskey.example',
  username: 'me',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> pumpSheet(
    WidgetTester tester,
    _Adapter adapter,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: DeckColumnsSheet())),
      ),
    );
    await tester.pump();
    return container;
  }

  group('#1155 読み込み中 / 0 件 / 失敗を書き分ける', () {
    testWidgets('⚠⚠ 読み込み中は「読み込んでいます」と出る（0 件と区別できる）', (tester) async {
      final adapter = _Adapter(channels: const []);
      await pumpSheet(tester, adapter);

      expect(find.text('リストを読み込んでいます…'), findsOneWidget);
      expect(
        find.text('リストがありません'),
        findsNothing,
        reason: '⚠ 読み込み中を「0 件」と言わない',
      );
    });

    testWidgets('⚠ 読み込み中でも、種別・通知・お知らせは選べるまま', (tester) async {
      final adapter = _Adapter(channels: const []);
      await pumpSheet(tester, adapter);

      expect(find.text('通知'), findsOneWidget);
      expect(find.text('お知らせ'), findsOneWidget);
    });

    testWidgets('取得できたら候補として並ぶ', (tester) async {
      final adapter = _Adapter(
        lists: const [PostList(id: '42', title: 'ダイ大')],
        channels: const [],
      );
      await pumpSheet(tester, adapter);
      await tester.pumpAndSettle();

      expect(find.text('ダイ大'), findsOneWidget);
      expect(find.text('リストを読み込んでいます…'), findsNothing);
    });

    testWidgets('0 件なら「がありません」と出る（待てば出ると誤解させない）', (tester) async {
      final adapter = _Adapter(lists: const [], channels: const []);
      await pumpSheet(tester, adapter);
      await tester.pumpAndSettle();

      expect(find.text('リストがありません'), findsOneWidget);
    });

    testWidgets('⚠ 失敗したら理由が出て、再試行できる', (tester) async {
      final adapter = _Adapter(lists: const [], channels: const [])
        ..failLists = true;
      await pumpSheet(tester, adapter);
      await tester.pumpAndSettle();

      expect(find.text('リストを取得できませんでした'), findsOneWidget);
      expect(find.text('再試行'), findsOneWidget);

      adapter.failLists = false;
      await tester.tap(find.text('再試行'));
      await tester.pumpAndSettle();

      expect(
        find.text('リストがありません'),
        findsOneWidget,
        reason: '再試行で取り直せている（今回は 0 件）',
      );
    });
  });

  group('#1156 シートを開くたびに取り直す', () {
    testWidgets('⚠⚠ 開き直すとフォロー中チャンネルを取り直す（再起動しないと出ない状態を作らない）', (tester) async {
      final adapter = _Adapter(lists: const [], channels: const []);
      final container = await pumpSheet(tester, adapter);
      await tester.pumpAndSettle();
      final first = adapter.channelCalls;
      expect(first, greaterThan(0));

      // シートを閉じて開き直す（同じコンテナ＝アプリを終了していない）。
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: SizedBox())),
        ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: DeckColumnsSheet())),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        adapter.channelCalls,
        greaterThan(first),
        reason: '⚠⚠ 取り直さないと、サーバーでフォローしても再起動まで出てこない',
      );
    });

    // ⚠ この 1 件は invalidate を外しても通る。listsProvider は autoDispose
    // なので、シートを閉じた時点で破棄され、開き直せばどのみち取り直すため。
    // **歯があるのは上のチャンネルの 1 件**（あちらは autoDispose を付けられない）。
    // ここは「リスト側も開き直しで最新になる」ことの回帰検査として置く。
    testWidgets('リストも同じく取り直す', (tester) async {
      final adapter = _Adapter(lists: const [], channels: const []);
      final container = await pumpSheet(tester, adapter);
      await tester.pumpAndSettle();
      final first = adapter.listCalls;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: SizedBox())),
        ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: DeckColumnsSheet())),
        ),
      );
      await tester.pumpAndSettle();

      expect(adapter.listCalls, greaterThan(first));
    });
  });

  group('#1158 AND 指定の案内', () {
    testWidgets('⚠ 入力欄に「+ でつなぐと AND」と出る（案内が無く入口が無いと受け取られた）', (tester) async {
      final adapter = _Adapter(lists: const [], channels: const []);
      await pumpSheet(tester, adapter);
      await tester.pumpAndSettle();

      expect(find.text('+ でつなぐと AND（例: nitiasa+precure）'), findsOneWidget);
    });
  });
}

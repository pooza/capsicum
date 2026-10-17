import 'dart:async';

import 'package:capsicum/src/provider/channel_provider.dart';
import 'package:capsicum/src/ui/widget/home_menu.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// チャンネルのタブ / カラムの名前 (#1296)。
///
/// 以前は `name ?? id` で、**読み戻したデッキのカラム（`name` が必ず null）と、
/// 名前なしで保存されたタブ UI のタブにチャンネル ID が出ていた。**
/// `tabLabel` を通して、引き直しの順（`name` → フォロー中 → 1 件取得 → ID）を固定する。
void main() {
  Future<String> label(
    WidgetTester tester, {
    required ChannelTab tab,
    required FutureOr<List<Channel>> Function() followed,
    Channel? Function(String id)? show,
    List<String>? shown,
  }) async {
    late String result;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          followedChannelsProvider.overrideWith((ref) => followed()),
          channelProvider.overrideWith((ref, id) async {
            shown?.add(id);
            return show?.call(id);
          }),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              result = tabLabel(ref, tab, false, null, const []);
              return Text(result);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('name があればそれを出す（取得しない）', (tester) async {
    final shown = <String>[];
    final text = await label(
      tester,
      tab: const ChannelTab(id: 'c1', name: '実況'),
      followed: () => const [],
      shown: shown,
    );
    expect(text, '実況');
    expect(shown, isEmpty);
  });

  testWidgets('⚠⚠ name が null なら、フォロー中の一覧から引く', (tester) async {
    final shown = <String>[];
    final text = await label(
      tester,
      tab: const ChannelTab(id: 'c1'),
      followed: () => const [Channel(id: 'c1', name: '実況')],
      shown: shown,
    );
    expect(text, '実況');
    expect(shown, isEmpty, reason: '一覧で引けたら 1 件取得はしない');
  });

  testWidgets('⚠⚠ フォローしていないチャンネルは 1 件取得で引く', (tester) async {
    final shown = <String>[];
    final text = await label(
      tester,
      tab: const ChannelTab(id: 'c2'),
      followed: () => const [Channel(id: 'c1', name: '実況')],
      show: (id) => Channel(id: id, name: '投稿から開いた'),
      shown: shown,
    );
    expect(text, '投稿から開いた');
    expect(shown, ['c2']);
  });

  testWidgets('フォロー中の一覧が失敗していても 1 件取得で引く', (tester) async {
    final text = await label(
      tester,
      tab: const ChannelTab(id: 'c2'),
      followed: () => Future.error(Exception('boom')),
      show: (id) => Channel(id: id, name: '投稿から開いた'),
    );
    expect(text, '投稿から開いた');
  });

  testWidgets('引けなければ ID に戻す', (tester) async {
    final text = await label(
      tester,
      tab: const ChannelTab(id: 'c2'),
      followed: () => const [],
      show: (_) => null,
    );
    expect(text, 'c2');
  });

  testWidgets('一覧の取得中は ID のまま待ち、全カラムぶん取りに行かない', (tester) async {
    final shown = <String>[];
    late String result;
    final pending = Completer<List<Channel>>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          followedChannelsProvider.overrideWith((ref) => pending.future),
          channelProvider.overrideWith((ref, id) async {
            shown.add(id);
            return null;
          }),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              result = tabLabel(
                ref,
                const ChannelTab(id: 'c1'),
                false,
                null,
                const [],
              );
              return Text(result);
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(result, 'c1');
    expect(shown, isEmpty);

    pending.complete(const [Channel(id: 'c1', name: '実況')]);
    await tester.pumpAndSettle();
    expect(result, '実況');
    expect(shown, isEmpty);
  });
}

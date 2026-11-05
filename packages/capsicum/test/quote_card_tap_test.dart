import 'package:capsicum/src/ui/widget/post_tile.dart';
import 'package:capsicum/src/ui/widget/preview_card_widget.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1364: 引用の枠の中のリンクとプレビューカードを押し分ける。
///
/// 修正前は本文がただの文字で、カードも出ておらず、枠のどこを押しても引用元を
/// 開いていた（デッキではスレッドのカラムが増える）。
const _url = 'https://example.test/release';

Post _quote({PreviewCard? card}) => Post(
  id: 'q1',
  postedAt: DateTime(2026, 11, 3),
  author: const User(id: 'u1', username: 'release_bot'),
  content: '<p><a href="$_url">$_url</a></p>',
  isHtml: true,
  card: card,
);

void main() {
  late List<String> launched;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // リンクを開く経路（openFediverseLink）が端末の設定を読む。
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    launched = [];
    // 外へ開くリンクは url_launcher に落ちる。開いた URL を記録する。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          (call) async {
            if (call.method == 'launch') {
              launched.add((call.arguments as Map)['url'] as String);
            }
            return true;
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          null,
        );
  });

  Future<void> pump(WidgetTester tester, Post quote) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: quoteCardForTest(quote),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/post',
          builder: (context, state) => const Text('引用元の画面'),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('本文のリンクを押すと、そのリンクが開き、引用元は開かない', (tester) async {
    await pump(tester, _quote());

    await tester.tap(find.byKey(quoteCardBodyKey));
    await tester.pumpAndSettle();

    expect(launched, [_url]);
    expect(find.text('引用元の画面'), findsNothing);
  });

  testWidgets('プレビューカードが枠の中に出て、押すとリンクが開く', (tester) async {
    const card = PreviewCard(url: _url, title: 'v2.9.0 のリリース');
    await pump(tester, _quote(card: card));

    expect(find.byType(PreviewCardWidget), findsOneWidget);
    await tester.tap(find.text('v2.9.0 のリリース'));
    await tester.pumpAndSettle();

    expect(launched, [_url]);
    expect(find.text('引用元の画面'), findsNothing);
  });

  testWidgets('名前の行を押すと、今までどおり引用元が開く', (tester) async {
    await pump(tester, _quote());

    await tester.tap(find.text('release_bot'));
    await tester.pumpAndSettle();

    expect(find.text('引用元の画面'), findsOneWidget);
    expect(launched, isEmpty);
  });
}

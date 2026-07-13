import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #820 回帰: 本文にベタ貼りされた URL（_NodeType.url）のタップが onLinkTap を
/// 通ること。以前は launchUrlSafely を直接呼んでおり、fediverse 投稿 URL の
/// アプリ内 resolve（openFediverseLink）を素通りしてブラウザ直行していた。
/// Misskey の MFM も Mastodon の <a href="url">url</a>（表示=URL）も、この
/// url ノードになるため両バックエンドで再現していた。
void main() {
  group('content_parser url ノードのタップ配線 (#820)', () {
    testWidgets('MFM のベタ貼り URL タップが onLinkTap に渡る', (tester) async {
      const url = 'https://misskey.example/notes/abcdef';
      String? tapped;
      final renderer = ContentRenderer(
        baseStyle: const TextStyle(),
        resolveEmoji: (_) => null,
        onLinkTap: (u) => tapped = u,
        // onLinkLongPress を与えると url ノードは GestureDetector になり
        // ウィジェットテストでタップしやすい（配線は recognizer 経路と共通）。
        onLinkLongPress: (_) {},
      );
      final span = renderer.renderMfm(url);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Text.rich(span))),
      );

      await tester.tap(find.byType(GestureDetector));
      expect(tapped, url);
      renderer.dispose();
    });

    testWidgets('Mastodon HTML の表示=URL リンクタップも onLinkTap に渡る', (tester) async {
      const url = 'https://mstdn.example/@alice/123';
      String? tapped;
      final renderer = ContentRenderer(
        baseStyle: const TextStyle(),
        resolveEmoji: (_) => null,
        onLinkTap: (u) => tapped = u,
        onLinkLongPress: (_) {},
      );
      final span = renderer.renderHtml(
        '<a href="$url" rel="nofollow noopener">$url</a>',
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Text.rich(span))),
      );

      await tester.tap(find.byType(GestureDetector));
      expect(tapped, url);
      renderer.dispose();
    });
  });
}

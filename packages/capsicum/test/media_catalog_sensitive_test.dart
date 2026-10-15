import 'package:capsicum/src/ui/screen/media_catalog_screen.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1284: メディアカタログは未認証で届く一覧なので、閲覧注意・CW つきの
/// メディアをぼかすのはクライアントの責任。本体のタイムラインと同じく
/// 「押すまで見せない」。
void main() {
  const image = MediaCatalogItem(
    id: '1',
    url: 'https://example.com/original.png',
    thumbnailUrl: 'https://example.com/small.png',
    mediatype: 'image',
    sensitive: true,
  );

  Future<({int Function() taps, int Function() reveals})> pump(
    WidgetTester tester, {
    required MediaCatalogItem item,
    required bool hidden,
  }) async {
    var taps = 0;
    var reveals = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 140,
              height: 140,
              child: MediaCatalogThumbnail(
                item: item,
                hidden: hidden,
                onTap: () => taps++,
                onReveal: () => reveals++,
              ),
            ),
          ),
        ),
      ),
    );
    return (taps: () => taps, reveals: () => reveals);
  }

  testWidgets('隠しているあいだは、ぼかして「閲覧注意」を重ねる', (tester) async {
    await pump(tester, item: image, hidden: true);

    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(find.text('閲覧注意'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
  });

  testWidgets('CW の文言があれば、それを見出しに使う', (tester) async {
    const item = MediaCatalogItem(
      id: '2',
      url: 'https://example.com/original.png',
      thumbnailUrl: 'https://example.com/small.png',
      mediatype: 'image',
      sensitive: true,
      spoilerText: 'ネタバレ',
    );
    await pump(tester, item: item, hidden: true);

    expect(find.text('ネタバレ'), findsOneWidget);
    expect(find.text('閲覧注意'), findsNothing);
  });

  testWidgets('隠しているあいだに押すと、詳細を開かずにぼかしを外す', (tester) async {
    final counts = await pump(tester, item: image, hidden: true);

    await tester.tap(find.byType(MediaCatalogThumbnail));
    expect(counts.reveals(), 1);
    expect(counts.taps(), 0);
  });

  testWidgets('見せているときは、ぼかしも重ねも無く、押すと詳細を開く', (tester) async {
    final counts = await pump(tester, item: image, hidden: false);

    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('閲覧注意'), findsNothing);
    expect(find.byIcon(Icons.visibility_off), findsNothing);

    await tester.tap(find.byType(MediaCatalogThumbnail));
    expect(counts.taps(), 1);
    expect(counts.reveals(), 0);
  });

  testWidgets('サムネイルの無いメディア（音声など）でも、隠しているあいだは重ねを出す', (tester) async {
    const audio = MediaCatalogItem(
      id: '3',
      url: 'https://example.com/sound.mp3',
      mediatype: 'audio',
      sensitive: true,
    );
    final counts = await pump(tester, item: audio, hidden: true);

    expect(find.text('閲覧注意'), findsOneWidget);
    await tester.tap(find.byType(MediaCatalogThumbnail));
    expect(counts.reveals(), 1);
    expect(counts.taps(), 0);
  });
}

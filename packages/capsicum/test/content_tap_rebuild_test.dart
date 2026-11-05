import 'package:capsicum/src/ui/widget/content_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1365: 押している最中に投稿の欄が組み直されると、本文のタップが外側の
/// `InkWell`（投稿を開く）へ流れる件。
///
/// PostTile と同じ構造（`LayoutBuilder` の中で本文の span を作り、外側の
/// `InkWell` が投稿を開く）を最小で組む。デッキではフォーカスの無いカラムを
/// 押した瞬間に画面全体が組み直されるので、pointer down の直後に組み直す。
const _mentionHtml =
    '<p><a href="https://fedibird.com/@BreadClub" class="u-url mention">'
    '@<span>BreadClub</span></a></p>';

class _Tile extends StatefulWidget {
  const _Tile({
    super.key,
    required this.useCache,
    required this.onMention,
    required this.onOpenPost,
  });

  /// false なら修正前の形（組み直すたびにレンダラを作り直して前のものを捨てる）。
  final bool useCache;
  final ValueChanged<String> onMention;
  final VoidCallback onOpenPost;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  final _spans = ContentSpanCache();
  ContentRenderer? _renderer;
  String content = _mentionHtml;
  int renderCount = 0;

  void rebuild([String? next]) => setState(() => content = next ?? content);

  @override
  void dispose() {
    _spans.dispose();
    _renderer?.dispose();
    super.dispose();
  }

  ContentRenderer _create(TextStyle baseStyle) {
    renderCount++;
    return ContentRenderer(
      baseStyle: baseStyle,
      resolveEmoji: (_) => null,
      onMentionTap: widget.onMention,
    );
  }

  TextSpan _render(TextStyle baseStyle) {
    if (widget.useCache) {
      return _spans.resolve(
        [content, baseStyle],
        () => _create(baseStyle),
        (renderer) => renderer.renderHtml(content),
      );
    }
    _renderer?.dispose();
    _renderer = _create(baseStyle);
    return _renderer!.renderHtml(content);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: widget.onOpenPost,
      child: LayoutBuilder(
        builder: (context, constraints) =>
            Text.rich(_render(DefaultTextStyle.of(context).style)),
      ),
    );
  }
}

class _Harness {
  final mentions = <String>[];
  var openedPost = 0;
  final key = GlobalKey<_TileState>();

  Future<void> pump(WidgetTester tester, {required bool useCache}) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: _Tile(
              key: key,
              useCache: useCache,
              onMention: mentions.add,
              onOpenPost: () => openedPost++,
            ),
          ),
        ),
      ),
    );
  }

  /// メンションを押し、離す前に欄を組み直す。
  Future<void> tapWhileRebuilding(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(RichText)),
    );
    key.currentState!.rebuild();
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }
}

void main() {
  group('押している最中の組み直し (#1365)', () {
    testWidgets('ContentSpanCache を通すと、メンションのタップは投稿を開かない', (tester) async {
      final h = _Harness();
      await h.pump(tester, useCache: true);

      await h.tapWhileRebuilding(tester);

      expect(h.openedPost, 0, reason: '外側の InkWell（投稿を開く）が鳴ってはいけない');
      expect(h.mentions, hasLength(1));
      expect(h.key.currentState!.renderCount, 1, reason: '中身が同じなら作り直さない');
    });

    testWidgets('対照: 組み直すたびに作り直すと、タップが投稿を開く側へ流れる', (tester) async {
      // ⚠ 修正前の形。これが緑になったら（Flutter の挙動が変わって）上の
      // テストが何も守っていないことになるので、原因から見直す。
      final h = _Harness();
      await h.pump(tester, useCache: false);

      await h.tapWhileRebuilding(tester);

      expect(h.openedPost, 1);
      expect(h.mentions, isEmpty);
    });

    testWidgets('組み直しが無ければ、どちらの形でもメンションに届く', (tester) async {
      for (final useCache in [true, false]) {
        final h = _Harness();
        await h.pump(tester, useCache: useCache);

        await tester.tap(find.byType(RichText));
        await tester.pumpAndSettle();

        expect(h.openedPost, 0, reason: 'useCache=$useCache');
        expect(h.mentions, hasLength(1), reason: 'useCache=$useCache');
      }
    });
  });

  group('ContentSpanCache', () {
    testWidgets('鍵が変わったら作り直し、新しい中身で描く', (tester) async {
      final h = _Harness();
      await h.pump(tester, useCache: true);
      expect(h.key.currentState!.renderCount, 1);

      h.key.currentState!.rebuild('<p>ほかの本文</p>');
      await tester.pump();

      expect(h.key.currentState!.renderCount, 2);
      expect(find.textContaining('ほかの本文', findRichText: true), findsOneWidget);
    });

    test('前回と同じ鍵なら同じ span を返し、変われば前のレンダラを捨てる', () {
      final cache = ContentSpanCache();
      final created = <_SpyRenderer>[];
      TextSpan resolve(List<Object?> key) => cache.resolve(key, () {
        final r = _SpyRenderer();
        created.add(r);
        return r;
      }, (r) => r.renderPlain('x'));

      final first = resolve(['a', 1]);
      expect(identical(resolve(['a', 1]), first), isTrue);
      expect(created, hasLength(1));

      resolve(['a', 2]);
      expect(created, hasLength(2));
      expect(created.first.disposed, isTrue);
      expect(created.last.disposed, isFalse);

      cache.dispose();
      expect(created.last.disposed, isTrue);
    });
  });
}

class _SpyRenderer extends ContentRenderer {
  _SpyRenderer()
    : super(baseStyle: const TextStyle(), resolveEmoji: (_) => null);

  var disposed = false;

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
